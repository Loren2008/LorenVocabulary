#!/usr/bin/env python3
"""Create and execute the words.db data-quality audit notebook."""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path

import nbformat as nbf
from nbclient import NotebookClient


PROJECT_DIR = Path(__file__).resolve().parents[1]
NOTEBOOK_PATH = PROJECT_DIR / "Analysis" / "words_db_quality.ipynb"
SUMMARY_PATH = PROJECT_DIR / "Analysis" / "words_db_quality_summary.json"


def code(source: str):
    return nbf.v4.new_code_cell(source.strip())


def markdown(source: str):
    return nbf.v4.new_markdown_cell(source.strip())


notebook = nbf.v4.new_notebook()
notebook["metadata"] = {
    "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
    "language_info": {"name": "python", "version": "3"},
}
notebook["cells"] = [
    markdown(
        """
# `words.db` 扩容质量验收

**TL;DR**：本 notebook 对发布后的离线词典执行完整性、键唯一性、JSON 结构、字段完整度、
专名展示、合法词形别名、来源真实性标记和典型规范化查询检查。末尾只有全部门禁通过才输出
`QUALITY_OK`。
"""
    ),
    markdown(
        """
## Context

- Canonical database: `Resources/words.db`
- Direct entries contain their own generated content.
- Legal inflected forms live in `word_aliases` and resolve to a direct lemma.
- Model-generated IELTS context is labelled `generated_style`; legacy material remains
  `legacy_unverified` and is not treated as verified exam text.
"""
    ),
    code(
        """
from pathlib import Path
import collections
import datetime as dt
import hashlib
import json
import os
import sqlite3
import unicodedata

def check(condition, message):
    if not condition:
        raise RuntimeError(message)

project_dir = Path.cwd()
db_path = project_dir / "Resources" / "words.db"
check(db_path.is_file(), f"Database not found: {db_path}")
connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
connection.row_factory = sqlite3.Row
database_sha256 = hashlib.sha256(db_path.read_bytes()).hexdigest()
print({
    "database": str(db_path),
    "database_sha256": database_sha256,
    "size_mib": round(db_path.stat().st_size / 1024 / 1024, 2),
})
"""
    ),
    markdown("## Database profile"),
    code(
        """
integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
required_tables = {"words", "word_metadata", "word_aliases", "expansion_runs"}
check(required_tables <= tables, f"Missing tables: {sorted(required_tables - tables)}")

profile = {
    "integrity": integrity,
    "direct_words": connection.execute("SELECT COUNT(*) FROM words").fetchone()[0],
    "aliases": connection.execute("SELECT COUNT(*) FROM word_aliases").fetchone()[0],
    "metadata": connection.execute("SELECT COUNT(*) FROM word_metadata").fetchone()[0],
    "expansion_runs": connection.execute("SELECT COUNT(*) FROM expansion_runs").fetchone()[0],
}
profile["offline_lookup_keys"] = profile["direct_words"] + profile["aliases"]
check(integrity == "ok", f"integrity_check failed: {integrity}")
check(
    profile["metadata"] == profile["direct_words"],
    f"metadata coverage mismatch: {profile}",
)
print(json.dumps(profile, ensure_ascii=False, indent=2))
"""
    ),
    markdown("## JSON and required-field validation"),
    code(
        """
def object_list(raw, required):
    try:
        value = json.loads(raw or "[]")
    except json.JSONDecodeError:
        return False
    if not isinstance(value, list) or not value:
        return False
    for item in value:
        if not isinstance(item, dict):
            return False
        if any(not isinstance(key, str) or not isinstance(member, str) for key, member in item.items()):
            return False
        if any(not isinstance(item.get(key), str) or not item[key].strip() for key in required):
            return False
    return True

quality_errors = []
keys = set()
for row in connection.execute(
    "SELECT word,definitions,phrases,ielts_examples FROM words ORDER BY word"
):
    key = row["word"]
    if key in keys:
        quality_errors.append((key, "duplicate_key"))
    keys.add(key)
    if key != unicodedata.normalize("NFKC", key).lower():
        quality_errors.append((key, "non_normalized_key"))
    if not object_list(row["definitions"], ("pos", "meaning", "example")):
        quality_errors.append((key, "definitions"))
    if not object_list(row["phrases"], ("text", "meaning", "type")):
        quality_errors.append((key, "phrases"))
    if not object_list(row["ielts_examples"], ("sentence", "source")):
        quality_errors.append((key, "ielts_examples"))

check(not quality_errors, f"Invalid App JSON rows: {quality_errors[:20]}")
print({"validated_direct_entries": len(keys), "quality_errors": len(quality_errors)})
"""
    ),
    markdown("## Alias, metadata, and provenance checks"),
    code(
        """
orphan_aliases = connection.execute(
    "SELECT COUNT(*) FROM word_aliases a LEFT JOIN words w ON w.word=a.lemma WHERE w.word IS NULL"
).fetchone()[0]
alias_collisions = connection.execute(
    "SELECT COUNT(*) FROM word_aliases a JOIN words w ON w.word=a.alias"
).fetchone()[0]
entry_types = dict(connection.execute(
    "SELECT entry_type,COUNT(*) FROM word_metadata GROUP BY entry_type ORDER BY entry_type"
).fetchall())
authenticity = dict(connection.execute(
    "SELECT content_authenticity,COUNT(*) FROM word_metadata "
    "GROUP BY content_authenticity ORDER BY content_authenticity"
).fetchall())
form_types = dict(connection.execute(
    "SELECT form_type,COUNT(*) FROM word_aliases GROUP BY form_type ORDER BY form_type"
).fetchall())

check(orphan_aliases == 0, f"Orphan aliases: {orphan_aliases}")
check(alias_collisions == 0, f"Direct/alias collisions: {alias_collisions}")
check("generated_style" in authenticity, "No generated_style metadata")
check("legacy_unverified" in authenticity, "No legacy_unverified metadata")
print(json.dumps({
    "entry_types": entry_types,
    "authenticity": authenticity,
    "form_types": form_types,
}, ensure_ascii=False, indent=2))
"""
    ),
    markdown("## Lookup regression samples"),
    code(
        """
def lookup_candidates(raw):
    value = unicodedata.normalize("NFKC", raw.strip())
    for old in "’‘ʼ＇":
        value = value.replace(old, "'")
    for old in "‐‑‒–—−－":
        value = value.replace(old, "-")
    value = " ".join(value.split())
    canonical = value.lower()
    stripped = canonical
    while stripped and not stripped[0].isalnum():
        stripped = stripped[1:]
    while stripped and not stripped[-1].isalnum():
        stripped = stripped[:-1]
    return list(dict.fromkeys(key for key in (canonical, stripped) if key))

def resolve(raw):
    for key in lookup_candidates(raw):
        direct = connection.execute(
            "SELECT COALESCE(m.display_word,w.word) display_word,w.word lemma,'direct' kind "
            "FROM words w LEFT JOIN word_metadata m ON m.word=w.word WHERE w.word=?",
            (key,),
        ).fetchone()
        if direct:
            return dict(direct)
        alias = connection.execute(
            "SELECT a.display_word,a.lemma,'alias' kind FROM word_aliases a WHERE a.alias=?",
            (key,),
        ).fetchone()
        if alias:
            return dict(alias)
    return None

regressions = {
    "Athens": resolve("Athens"),
    "quoted_athens": resolve("“Athens,”"),
    "smart_apostrophe": resolve("can’t"),
    "unicode_hyphen": resolve("off‑putting"),
}
alias_sample = connection.execute("SELECT alias FROM word_aliases ORDER BY alias LIMIT 1").fetchone()[0]
regressions[f"alias:{alias_sample}"] = resolve(alias_sample.upper())
check(all(regressions.values()), f"Lookup regressions failed: {regressions}")
check(
    regressions[f"alias:{alias_sample}"]["kind"] == "alias",
    f"Alias did not resolve as alias: {regressions}",
)
print(json.dumps(regressions, ensure_ascii=False, indent=2))
"""
    ),
    markdown("## Published run and final takeaways"),
    code(
        """
latest_run_row = connection.execute(
    "SELECT * FROM expansion_runs ORDER BY published_at DESC LIMIT 1"
).fetchone()
check(latest_run_row is not None, "No published expansion run found")
latest_run = dict(latest_run_row)
summary = {
    "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "database_sha256": database_sha256,
    "profile": profile,
    "entry_types": entry_types,
    "authenticity": authenticity,
    "form_types": form_types,
    "latest_run": latest_run,
    "regressions": regressions,
    "status": "QUALITY_OK",
}
summary_path = project_dir / "Analysis" / "words_db_quality_summary.json"
summary_tmp = summary_path.with_suffix(f"{summary_path.suffix}.tmp")
summary_tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")
os.replace(summary_tmp, summary_path)
connection.close()
print("QUALITY_OK")
print(summary_path)
"""
    ),
]

NOTEBOOK_PATH.parent.mkdir(parents=True, exist_ok=True)


def write_status(status: str, error: str | None = None) -> None:
    payload = {
        "status": status,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    if error:
        payload["error"] = error[:1000]
    temporary = SUMMARY_PATH.with_suffix(f"{SUMMARY_PATH.suffix}.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, SUMMARY_PATH)


# Replace prior successful artifacts before execution so a failing rerun can
# never leave a stale QUALITY_OK result behind.
write_status("RUNNING")
nbf.write(notebook, NOTEBOOK_PATH)
client = NotebookClient(
    notebook,
    timeout=600,
    kernel_name="python3",
    resources={"metadata": {"path": str(PROJECT_DIR)}},
)
try:
    client.execute(cwd=str(PROJECT_DIR))
except Exception as error:
    write_status("FAILED", f"{type(error).__name__}: {error}")
    nbf.write(notebook, NOTEBOOK_PATH)
    raise
nbf.write(notebook, NOTEBOOK_PATH)
print(NOTEBOOK_PATH)
