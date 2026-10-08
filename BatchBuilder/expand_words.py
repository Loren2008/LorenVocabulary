#!/usr/bin/env python3
"""Generate, validate, resume, and atomically publish DeepSeek dictionary entries.

Secrets are read from DEEPSEEK_API_KEY or an existing Config.plist and are never
written to source, argv, logs, manifests, or SQLite. Network workers only write to a
run-state database; the canonical Resources/words.db is replaced only after the
entire staged database passes integrity and schema checks.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import fcntl
import hashlib
import json
import os
import plistlib
import random
import re
import sqlite3
import ssl
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


PROJECT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_DB = PROJECT_DIR / "Resources" / "words.db"
DEFAULT_CANDIDATES = PROJECT_DIR / "BatchBuilder" / "generated" / "expansion_candidates.jsonl"
DEFAULT_ALIASES = PROJECT_DIR / "BatchBuilder" / "generated" / "inflection_aliases.jsonl"
DEFAULT_SUMMARY = PROJECT_DIR / "BatchBuilder" / "generated" / "expansion_candidates.summary.json"
DEFAULT_RUN_DIR = Path.home() / ".ielts-vocab" / "expansion-runs"
DEFAULT_BACKUP_DIR = Path.home() / ".ielts-vocab" / "backups"
PROMPT_VERSION = "expansion-v5-evidence-subtype-headword-json-style-example"
VALIDATOR_VERSION = "app-json-v2-field-merge-alias-collision-gate"
DEFAULT_MODEL = "deepseek-v4-flash"
PHRASE_TYPES = {"formal", "slang", "idiom", "phrasalVerb", "collocation"}
PHRASE_TYPE_ALIASES = {
    "phrasal_verb": "phrasalVerb",
    "phrasal verb": "phrasalVerb",
    "phrasalverb": "phrasalVerb",
    "informal": "slang",
    "colloquial": "slang",
    "dialect": "slang",
    "technical": "collocation",
    "proper_noun": "collocation",
    "proper noun": "collocation",
    "historical": "formal",
    "exclamation": "idiom",
    "fixed_expression": "idiom",
    "fixed expression": "idiom",
    "expression": "collocation",
    "sports": "collocation",
    "medical": "collocation",
    "archaic": "formal",
}
CHINESE_RE = re.compile(r"[\u3400-\u9fff]")
SECRET_RE = re.compile(r"sk-[A-Za-z0-9_-]+")


class FatalAPIError(RuntimeError):
    pass


class RetryableAPIError(RuntimeError):
    pass


@dataclass
class BatchOutcome:
    success: dict[str, dict[str, Any]] = field(default_factory=dict)
    rejected: dict[str, str] = field(default_factory=dict)
    retry: dict[str, str] = field(default_factory=dict)
    usage: dict[str, int] = field(default_factory=dict)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--candidates", type=Path, default=DEFAULT_CANDIDATES)
    parser.add_argument("--aliases", type=Path, default=DEFAULT_ALIASES)
    parser.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument("--run-dir", type=Path, default=DEFAULT_RUN_DIR)
    parser.add_argument(
        "--reuse-state",
        type=Path,
        help="Safely import semantically compatible successful jobs from an older run state",
    )
    parser.add_argument("--backup-dir", type=Path, default=DEFAULT_BACKUP_DIR)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=6)
    parser.add_argument("--max-attempts", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="Pilot on the first N manifest rows")
    parser.add_argument(
        "--categories",
        default="",
        help="Comma-separated subset: repair,general_gap,inflected_lexeme,proper_noun,rare_word",
    )
    parser.add_argument("--words", default="", help="Comma-separated exact candidate keys")
    parser.add_argument("--no-publish", action="store_true")
    parser.add_argument(
        "--publish-partial",
        action="store_true",
        help="Explicitly allow publishing a --limit/--categories/--words selection",
    )
    parser.add_argument(
        "--retry-quarantined",
        action="store_true",
        help="Explicitly reset quarantined/rejected jobs for another attempt",
    )
    return parser.parse_args()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def normalize_word(value: str) -> str:
    value = unicodedata.normalize("NFKC", value.strip())
    value = value.replace("’", "'").replace("‘", "'").replace("ʼ", "'")
    for character in "‐‑‒–—−－":
        value = value.replace(character, "-")
    value = " ".join(value.split())
    return value.lower()


def fold_for_match(value: str) -> str:
    value = unicodedata.normalize("NFKD", normalize_word(value))
    return "".join(character for character in value if not unicodedata.combining(character))


def lexical_token_variants(value: str) -> set[tuple[str, ...]]:
    """Tokenize spelling-equivalent compound and possessive forms.

    Both `lenzs-law`/`Lenz's law` and `speed-of-light`/`speed of light`
    compare equal, while a short headword can never match inside another token.
    """
    folded = fold_for_match(value)
    forms = {
        folded.replace("'", ""),
        re.sub(r"(?<=\w)'s\b", "", folded),
    }
    return {
        tuple(re.findall(r"[^\W_]+", form, flags=re.UNICODE))
        for form in forms
        if re.findall(r"[^\W_]+", form, flags=re.UNICODE)
    }


def phrase_contains_headword(headword: str, phrase: str) -> bool:
    headword_variants = lexical_token_variants(headword)
    phrase_variants = lexical_token_variants(phrase)
    for needle in headword_variants:
        for tokens in phrase_variants:
            width = len(needle)
            if any(tokens[index : index + width] == needle for index in range(len(tokens) - width + 1)):
                return True
    return False


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sanitize_error(error: Any, limit: int = 500) -> str:
    value = SECRET_RE.sub("[redacted]", str(error)).replace("\n", " ").strip()
    return value[:limit]


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"Invalid JSONL at {path}:{line_number}: {error}") from error
            if not isinstance(item, dict) or not isinstance(item.get("word"), str):
                raise SystemExit(f"Invalid candidate at {path}:{line_number}")
            rows.append(item)
    return rows


def validate_manifest_summary(
    summary_path: Path,
    database_path: Path,
    candidates_path: Path,
    aliases_path: Path,
) -> dict[str, Any]:
    """Bind generated manifests to the exact source database and summary."""
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Invalid expansion summary {summary_path}: {error}") from error
    if not isinstance(summary, dict):
        raise SystemExit(f"Expansion summary is not an object: {summary_path}")

    direct_rows = load_jsonl(candidates_path)
    alias_rows = load_jsonl(aliases_path)
    outputs = summary.get("outputs")
    if not isinstance(outputs, dict):
        raise SystemExit("Expansion summary is missing outputs")
    expected = {
        "database_sha256": (summary.get("database_sha256"), sha256_file(database_path)),
        "direct_sha256": (outputs.get("direct_sha256"), sha256_file(candidates_path)),
        "aliases_sha256": (outputs.get("aliases_sha256"), sha256_file(aliases_path)),
        "direct_candidates": (summary.get("direct_candidates"), len(direct_rows)),
        "inflection_aliases": (summary.get("inflection_aliases"), len(alias_rows)),
    }
    mismatches = [
        f"{key}: summary={recorded!r}, actual={actual!r}"
        for key, (recorded, actual) in expected.items()
        if recorded != actual
    ]
    if mismatches:
        raise SystemExit("Expansion manifest verification failed: " + "; ".join(mismatches))
    return summary


def select_candidates(arguments: argparse.Namespace) -> list[dict[str, Any]]:
    rows = load_jsonl(arguments.candidates)
    if arguments.categories:
        allowed = {value.strip() for value in arguments.categories.split(",") if value.strip()}
        rows = [row for row in rows if row.get("category") in allowed]
    if arguments.words:
        requested = {
            normalize_word(value) for value in arguments.words.split(",") if value.strip()
        }
        rows = [row for row in rows if normalize_word(row["word"]) in requested]
        missing = requested - {normalize_word(row["word"]) for row in rows}
        if missing:
            raise SystemExit(f"Requested words are not in the candidate manifest: {sorted(missing)}")
    if arguments.limit > 0:
        rows = rows[: arguments.limit]
    if not rows:
        raise SystemExit("No candidates selected")
    words = [normalize_word(row["word"]) for row in rows]
    if len(words) != len(set(words)):
        raise SystemExit("Candidate manifest contains duplicate normalized words")
    return rows


def validate_publish_scope(arguments: argparse.Namespace) -> None:
    partial_selection = bool(arguments.limit or arguments.categories or arguments.words)
    if partial_selection and not arguments.no_publish and not arguments.publish_partial:
        raise SystemExit(
            "Partial selection is non-publishable by default; use --no-publish or "
            "explicitly acknowledge with --publish-partial"
        )


def read_config() -> tuple[str, str]:
    environment_key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    environment_base = os.environ.get("DEEPSEEK_BASE_URL", "").strip()
    if environment_key:
        return environment_key, environment_base or "https://api.deepseek.com"

    paths = [
        Path.home() / ".ielts-vocab" / "Config.plist",
        PROJECT_DIR / "Resources" / "Config.plist",
    ]
    for path in paths:
        if not path.is_file():
            continue
        try:
            with path.open("rb") as handle:
                config = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException):
            continue
        key = str(config.get("deepseekAPIKey", "")).strip()
        base = str(config.get("deepseekBaseURL", "")).strip()
        if key and key != "YOUR_API_KEY":
            return key, base or "https://api.deepseek.com"
    raise SystemExit("DeepSeek API key is missing; set DEEPSEEK_API_KEY or provide Config.plist")


def endpoint_from_base(base_url: str) -> str:
    parsed = urllib.parse.urlsplit(base_url.strip())
    try:
        port = parsed.port
    except ValueError as error:
        raise SystemExit(f"Invalid DeepSeek endpoint port: {error}") from error
    if (
        parsed.scheme.lower() != "https"
        or parsed.hostname != "api.deepseek.com"
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 443}
        or parsed.query
        or parsed.fragment
    ):
        raise SystemExit(
            "DeepSeek endpoint must use official HTTPS host https://api.deepseek.com"
        )
    path = parsed.path.rstrip("/")
    if path in {"", "/v1"}:
        path = f"{path}/chat/completions"
    elif path not in {"/chat/completions", "/v1/chat/completions"}:
        raise SystemExit(f"Unsupported DeepSeek API path: {parsed.path}")
    return urllib.parse.urlunsplit(("https", "api.deepseek.com", path, "", ""))


class NoAuthorizationRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Turn redirects into HTTP errors so the bearer token is never forwarded."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def build_prompt(candidates: list[dict[str, Any]]) -> str:
    compact = [
        {
            "word": item["word"],
            "display_word": item.get("display_word", item["word"]),
            "category": item.get("category", "rare_word"),
            "subtype": item.get("subtype", ""),
            "lemma": item.get("lemma", item["word"]),
            "promoted_direct_type": item.get("promoted_direct_type", ""),
            "provenance": item.get("provenance", []),
        }
        for item in candidates
    ]
    return f"""
为下列英语词典候选生成简洁、可靠的英汉词条。只输出 JSON 对象，不要 Markdown。

候选：{json.dumps(compact, ensure_ascii=False, separators=(',', ':'))}

严格输出结构：
{{"results":[{{"word":"必须与候选 word 完全一致","accepted":true,"reason":"",\
"phonetic":"IPA或空字符串","definitions":[{{"pos":"词性","meaning":"20字以内中文释义",\
"example":"自然的英文例句"}}],"phrases":[{{"text":"常见搭配或固定表达",\
"meaning":"中文解释","type":"formal|slang|idiom|phrasalVerb|collocation"}}],\
"ielts_style_sentence":"原创的 IELTS 风格英文例句"}}]}}

规则：
1. 每个候选必须返回一次，不得添加候选外的词，不得重复。
2. 候选附带本地来源证据。不要仅因词语生僻、古旧、专业、方言、冒犯性、是缩写、是人名或查询键为小写而拒绝；应在中文释义中准确标注使用限制。只有无法根据 word、display_word、subtype 和 provenance 可靠识别时才 accepted=false，并写清原因，供管线隔离。
3. accepted=true 时 definitions 1至3条、phrases 1至3条，所有字段非空；释义使用简体中文，英文例句简洁自然。
4. 每条 phrases.text 都必须直接包含该候选的 word 或 display_word（大小写可不同），并且确实是该词的常见搭配、固定表达或可学习构式。禁止只给词源相关词或形近词；例如 chopper 不得配 pork chop。专名没有固定搭配时，可用 city of X、X language、X's work、the name X 等真实自然构式。
5. category=proper_noun 时，以 subtype 确认命名实体义；仅真正的专名义标 proper noun，并在相关时同时覆盖名词、形容词或普通词义（例如语言名及其形容词用法）。若 subtype 缺失，只给保守的名称类别解释，不要猜测具体人物身份或臆造经历。promoted_direct_type 非空时按该类型解释合法提升为直查的词形。
6. ielts_style_sentence 必须原创且适合雅思阅读/写作语境。你没有授权真题语料，禁止声称它来自剑桥雅思或任何真实考题。
7. accepted=false 时仍保留 word、accepted、reason；该候选不会发布，并会进入隔离队列等待人工检查。
""".strip()


def api_request(
    candidates: list[dict[str, Any]], api_key: str, endpoint: str, model: str
) -> tuple[dict[str, Any], dict[str, int]]:
    body = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "你是严谨的英汉词典编辑。你必须输出合法 JSON；所有候选均已本地验证，不得因生僻或专名而拒绝。",
            },
            {"role": "user", "content": build_prompt(candidates)},
        ],
        "thinking": {"type": "disabled"},
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
        "max_tokens": 8192,
        "user_id": "ielts_vocab_expansion",
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        NoAuthorizationRedirectHandler(),
    )
    try:
        with opener.open(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        status = error.code
        detail = sanitize_error(error.read().decode("utf-8", errors="replace"), 300)
        if status in {401, 402, 403}:
            raise FatalAPIError(f"HTTP {status}: {detail}") from error
        if status in {408, 409, 429, 500, 502, 503, 504}:
            raise RetryableAPIError(f"HTTP {status}: {detail}") from error
        raise FatalAPIError(f"HTTP {status}: {detail}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise RetryableAPIError(sanitize_error(error)) from error

    try:
        response = json.loads(raw)
        choice = response["choices"][0]
        finish_reason = choice.get("finish_reason")
        if finish_reason not in {None, "stop"}:
            raise RetryableAPIError(f"finish_reason={finish_reason}")
        content = choice["message"]["content"]
        result = json.loads(content)
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise RetryableAPIError(f"invalid API JSON: {sanitize_error(error)}") from error
    if not isinstance(result, dict):
        raise RetryableAPIError("model content is not a JSON object")
    usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}
    clean_usage = {
        key: int(value)
        for key, value in usage.items()
        if key in {"prompt_tokens", "completion_tokens", "total_tokens"}
        and isinstance(value, (int, float))
    }
    return result, clean_usage


def required_string(item: dict[str, Any], key: str, maximum: int) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} is empty or not a string")
    value = " ".join(value.split())
    if len(value) > maximum:
        raise ValueError(f"{key} exceeds {maximum} characters")
    if any(ord(character) < 32 for character in value):
        raise ValueError(f"{key} contains control characters")
    return value


def validate_entry(item: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    definitions = item.get("definitions")
    if not isinstance(definitions, list) or not 1 <= len(definitions) <= 8:
        raise ValueError("definitions must contain 1..8 items")
    clean_definitions: list[dict[str, str]] = []
    for definition in definitions:
        if not isinstance(definition, dict):
            raise ValueError("definition is not an object")
        pos = required_string(definition, "pos", 40)
        meaning = required_string(definition, "meaning", 80)
        example = required_string(definition, "example", 400)
        if not CHINESE_RE.search(meaning):
            raise ValueError("definition meaning is not Chinese")
        clean_definitions.append({"pos": pos, "meaning": meaning, "example": example})

    phrases = item.get("phrases")
    if not isinstance(phrases, list) or not 1 <= len(phrases) <= 8:
        raise ValueError("phrases must contain 1..8 items")
    clean_phrases: list[dict[str, str]] = []
    for phrase in phrases:
        if not isinstance(phrase, dict):
            raise ValueError("phrase is not an object")
        text = required_string(phrase, "text", 160)
        meaning = required_string(phrase, "meaning", 120)
        phrase_type = required_string(phrase, "type", 40)
        phrase_type = PHRASE_TYPE_ALIASES.get(phrase_type.lower(), phrase_type)
        if phrase_type not in PHRASE_TYPES:
            raise ValueError(f"unsupported phrase type: {phrase_type}")
        if not CHINESE_RE.search(meaning):
            raise ValueError("phrase meaning is not Chinese")
        if not phrase_contains_headword(candidate["word"], text):
            raise ValueError("phrase does not contain the headword")
        clean_phrases.append({"text": text, "meaning": meaning, "type": phrase_type})

    sentence = required_string(item, "ielts_style_sentence", 500)
    phonetic = item.get("phonetic", "")
    if not isinstance(phonetic, str):
        raise ValueError("phonetic is not a string")
    phonetic = " ".join(phonetic.split())[:100]
    return {
        "word": candidate["word"],
        "display_word": candidate.get("display_word", candidate["word"]),
        "category": candidate.get("category", "rare_word"),
        "lemma": candidate.get("lemma", candidate["word"]),
        "provenance": candidate.get("provenance", []),
        "phonetic": phonetic,
        "definitions": clean_definitions,
        "phrases": clean_phrases,
        "ielts_examples": [
            {
                "sentence": sentence,
                "source": "AI-generated IELTS-style example",
                "year": "",
            }
        ],
    }


def process_batch(
    candidates: list[dict[str, Any]], api_key: str, endpoint: str, model: str
) -> BatchOutcome:
    outcome = BatchOutcome()
    expected = {normalize_word(item["word"]): item for item in candidates}
    try:
        response, outcome.usage = api_request(candidates, api_key, endpoint, model)
    except RetryableAPIError as error:
        message = sanitize_error(error)
        outcome.retry = {word: message for word in expected}
        return outcome

    results = response.get("results")
    if not isinstance(results, list):
        outcome.retry = {word: "results is not an array" for word in expected}
        return outcome

    seen: set[str] = set()
    for item in results:
        if not isinstance(item, dict) or not isinstance(item.get("word"), str):
            continue
        word = normalize_word(item["word"])
        if word not in expected or word in seen:
            continue
        seen.add(word)
        candidate = expected[word]
        accepted = item.get("accepted")
        if accepted is False:
            reason = sanitize_error(item.get("reason", "model rejected candidate"), 200)
            outcome.rejected[word] = f"validated candidate was rejected: {reason}"
            continue
        if accepted is not True:
            outcome.retry[word] = "accepted is not a boolean true/false"
            continue
        try:
            outcome.success[word] = validate_entry(item, candidate)
        except ValueError as error:
            outcome.retry[word] = sanitize_error(error)

    for word in expected.keys() - seen:
        outcome.retry[word] = "word missing from model response"
    return outcome


BASE_STATE_SEMANTIC_KEYS = (
    "word",
    "display_word",
    "category",
    "lemma",
    "promoted_direct_type",
)


def candidate_semantics(candidate: dict[str, Any]) -> dict[str, Any]:
    """Fields that can change what content the model should generate.

    repair_fields is intentionally excluded: it only controls which validated
    columns are merged into an existing row and does not change generated prose.
    """
    defaults: dict[str, Any] = {
        "display_word": candidate.get("word", ""),
        "category": "rare_word",
        "lemma": candidate.get("word", ""),
        "subtype": "",
        "promoted_direct_type": "",
        "provenance": [],
    }
    semantics = {
        key: candidate.get(key, defaults.get(key))
        for key in BASE_STATE_SEMANTIC_KEYS
    }
    if semantics["category"] == "proper_noun":
        # Proper-name identity/category is evidence-sensitive. Old v4 proper
        # payloads had no subtype context and must be regenerated.
        semantics["subtype"] = candidate.get("subtype", "")
        semantics["provenance"] = candidate.get("provenance", [])
    return semantics


def stored_payload_is_valid(payload: Any, candidate: dict[str, Any]) -> bool:
    if not isinstance(payload, dict):
        return False
    if normalize_word(str(payload.get("word", ""))) != normalize_word(candidate["word"]):
        return False
    if payload.get("display_word") != candidate.get("display_word", candidate["word"]):
        return False
    if payload.get("category") != candidate.get("category", "rare_word"):
        return False
    if normalize_word(str(payload.get("lemma", ""))) != normalize_word(
        str(candidate.get("lemma", candidate["word"]))
    ):
        return False
    definitions = payload.get("definitions")
    phrases = payload.get("phrases")
    ielts = payload.get("ielts_examples")
    if not strict_object_list_value(definitions, ("pos", "meaning", "example")):
        return False
    if not strict_object_list_value(phrases, ("text", "meaning", "type")):
        return False
    if not strict_object_list_value(ielts, ("sentence", "source")):
        return False
    for phrase in phrases:
        if phrase["type"] not in PHRASE_TYPES:
            return False
        if not CHINESE_RE.search(phrase["meaning"]):
            return False
        if not phrase_contains_headword(candidate["word"], phrase["text"]):
            return False
    return all(CHINESE_RE.search(item["meaning"]) for item in definitions)


def import_compatible_successes(
    connection: sqlite3.Connection,
    reuse_state_path: Path,
    candidates: list[dict[str, Any]],
) -> int:
    if not reuse_state_path.is_file():
        raise SystemExit(f"Reuse state not found: {reuse_state_path}")
    source = sqlite3.connect(f"file:{reuse_state_path}?mode=ro", uri=True)
    try:
        source_rows = source.execute(
            "SELECT word,candidate_json,payload_json FROM jobs "
            "WHERE status='success' AND payload_json IS NOT NULL"
        ).fetchall()
    except sqlite3.DatabaseError as error:
        source.close()
        raise SystemExit(f"Invalid reuse state {reuse_state_path}: {error}") from error

    selected = {normalize_word(item["word"]): item for item in candidates}
    imported = 0
    timestamp = now_iso()
    for word, candidate_json, payload_json in source_rows:
        target_candidate = selected.get(normalize_word(word))
        if target_candidate is None:
            continue
        try:
            old_candidate = json.loads(candidate_json)
            payload = json.loads(payload_json)
        except (TypeError, json.JSONDecodeError):
            continue
        if candidate_semantics(old_candidate) != candidate_semantics(target_candidate):
            continue
        if not stored_payload_is_valid(payload, target_candidate):
            continue
        # Provenance is audit metadata for non-proper entries. Rebase it to the
        # current manifest without pretending the generated prose changed.
        payload["provenance"] = target_candidate.get("provenance", [])
        cursor = connection.execute(
            "UPDATE jobs SET status='success',payload_json=?,last_error=NULL,updated_at=? "
            "WHERE word=? AND status!='success'",
            (json.dumps(payload, ensure_ascii=False, sort_keys=True), timestamp, normalize_word(word)),
        )
        imported += cursor.rowcount
    source.close()
    connection.execute(
        "INSERT OR REPLACE INTO run_metadata(key,value) VALUES (?,?)",
        ("audit.reused_success_count", str(imported)),
    )
    connection.execute(
        "INSERT OR REPLACE INTO run_metadata(key,value) VALUES (?,?)",
        ("audit.reuse_state_sha256", sha256_file(reuse_state_path)),
    )
    connection.commit()
    return imported


def revalidate_state_successes(
    connection: sqlite3.Connection, candidates: list[dict[str, Any]]
) -> int:
    selected = {normalize_word(item["word"]): item for item in candidates}
    invalid: list[str] = []
    for word, payload_json in connection.execute(
        "SELECT word,payload_json FROM jobs WHERE status='success'"
    ):
        candidate = selected.get(word)
        try:
            payload = json.loads(payload_json or "null")
        except json.JSONDecodeError:
            payload = None
        if candidate is None or not stored_payload_is_valid(payload, candidate):
            invalid.append(word)
    if invalid:
        timestamp = now_iso()
        connection.executemany(
            "UPDATE jobs SET status='pending',attempts=0,payload_json=NULL,"
            "last_error='stored payload failed current validator',updated_at=? WHERE word=?",
            [(timestamp, word) for word in invalid],
        )
        connection.commit()
    return len(invalid)


def initialize_state(
    state_path: Path,
    candidates: list[dict[str, Any]],
    retry_quarantined: bool,
    expected_metadata: dict[str, str],
) -> sqlite3.Connection:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(state_path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            word TEXT PRIMARY KEY,
            candidate_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            payload_json TEXT,
            last_error TEXT,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        )
        """
    )
    connection.execute(
        "CREATE TABLE IF NOT EXISTS run_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)"
    )
    existing_metadata = dict(
        connection.execute(
            "SELECT key,value FROM run_metadata WHERE key NOT LIKE 'audit.%'"
        ).fetchall()
    )
    if existing_metadata:
        mismatches = [
            f"{key}: state={existing_metadata.get(key)!r}, current={value!r}"
            for key, value in expected_metadata.items()
            if existing_metadata.get(key) != value
        ]
        extras = sorted(set(existing_metadata) - set(expected_metadata))
        if extras:
            mismatches.append(f"unexpected state metadata keys={extras}")
        if mismatches:
            connection.close()
            raise SystemExit(
                "Run state metadata does not match this source/configuration: "
                + "; ".join(mismatches)
            )
    for candidate in candidates:
        word = normalize_word(candidate["word"])
        candidate_json = json.dumps(candidate, ensure_ascii=False, sort_keys=True)
        existing_job = connection.execute(
            "SELECT candidate_json FROM jobs WHERE word=?", (word,)
        ).fetchone()
        if existing_job is not None:
            try:
                existing_candidate = json.loads(existing_job[0])
            except json.JSONDecodeError as error:
                connection.close()
                raise SystemExit(f"Run state contains invalid candidate JSON for {word}") from error
            if candidate_semantics(existing_candidate) != candidate_semantics(candidate):
                connection.close()
                raise SystemExit(f"Run state candidate semantics changed for {word}")
        connection.execute(
            "INSERT OR IGNORE INTO jobs(word,candidate_json,updated_at) VALUES (?,?,?)",
            (
                word,
                candidate_json,
                now_iso(),
            ),
        )
    selected_words = {normalize_word(item["word"]) for item in candidates}
    placeholders = ",".join("?" for _ in selected_words)
    connection.execute(f"DELETE FROM jobs WHERE word NOT IN ({placeholders})", tuple(selected_words))
    if retry_quarantined:
        connection.execute(
            "UPDATE jobs SET status='pending', attempts=0, last_error=NULL "
            "WHERE status IN ('quarantined','rejected')"
        )
    if not existing_metadata:
        connection.executemany(
            "INSERT INTO run_metadata(key,value) VALUES (?,?)",
            sorted(expected_metadata.items()),
        )
    connection.commit()
    return connection


def state_counts(connection: sqlite3.Connection) -> dict[str, int]:
    counts = {row[0]: row[1] for row in connection.execute("SELECT status,COUNT(*) FROM jobs GROUP BY status")}
    counts["total"] = connection.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
    return counts


def publishability(connection: sqlite3.Connection) -> dict[str, int]:
    result = {
        "pending": connection.execute(
            "SELECT COUNT(*) FROM jobs WHERE status='pending'"
        ).fetchone()[0],
        "repair_not_success": connection.execute(
            "SELECT COUNT(*) FROM jobs WHERE status!='success' "
            "AND json_extract(candidate_json,'$.category')='repair'"
        ).fetchone()[0],
        "excluded_nonrepair": connection.execute(
            "SELECT COUNT(*) FROM jobs WHERE status IN ('quarantined','rejected') "
            "AND json_extract(candidate_json,'$.category')!='repair'"
        ).fetchone()[0],
        "unexpected_status": connection.execute(
            "SELECT COUNT(*) FROM jobs WHERE status NOT IN "
            "('pending','success','quarantined','rejected')"
        ).fetchone()[0],
    }
    return result


def run_generation(
    connection: sqlite3.Connection,
    arguments: argparse.Namespace,
    api_key: str,
    endpoint: str,
) -> dict[str, int]:
    completed_batches = 0
    while True:
        pending_rows = connection.execute(
            "SELECT word,candidate_json,attempts FROM jobs "
            "WHERE status='pending' AND attempts < ? ORDER BY attempts,word",
            (arguments.max_attempts,),
        ).fetchall()
        if not pending_rows:
            break

        minimum_attempt = min(row[2] for row in pending_rows)
        if minimum_attempt:
            time.sleep(min(20.0, (2 ** minimum_attempt) + random.random()))

        batches: list[tuple[list[str], list[dict[str, Any]]]] = []
        for offset in range(0, len(pending_rows), arguments.batch_size):
            group = pending_rows[offset : offset + arguments.batch_size]
            batches.append(
                ([row[0] for row in group], [json.loads(row[1]) for row in group])
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.workers) as executor:
            batch_iterator = iter(batches)
            future_map: dict[concurrent.futures.Future, list[dict[str, Any]]] = {}

            def submit_next() -> bool:
                try:
                    words, batch = next(batch_iterator)
                except StopIteration:
                    return False
                timestamp = now_iso()
                connection.executemany(
                    "UPDATE jobs SET attempts=attempts+1,updated_at=? "
                    "WHERE word=? AND status='pending'",
                    [(timestamp, word) for word in words],
                )
                connection.commit()
                future = executor.submit(
                    process_batch, batch, api_key, endpoint, arguments.model
                )
                future_map[future] = batch
                return True

            for _ in range(min(arguments.workers, len(batches))):
                submit_next()
            try:
                while future_map:
                    done, _ = concurrent.futures.wait(
                        future_map, return_when=concurrent.futures.FIRST_COMPLETED
                    )
                    for future in done:
                        batch = future_map.pop(future)
                        outcome = future.result()
                        prompt_share = outcome.usage.get("prompt_tokens", 0) // max(1, len(batch))
                        completion_share = outcome.usage.get("completion_tokens", 0) // max(1, len(batch))
                        for word, payload in outcome.success.items():
                            connection.execute(
                                "UPDATE jobs SET status='success',payload_json=?,last_error=NULL,"
                                "prompt_tokens=prompt_tokens+?,completion_tokens=completion_tokens+?,updated_at=? WHERE word=?",
                                (
                                    json.dumps(payload, ensure_ascii=False, sort_keys=True),
                                    prompt_share,
                                    completion_share,
                                    now_iso(),
                                    word,
                                ),
                            )
                        for word, reason in outcome.rejected.items():
                            connection.execute(
                                "UPDATE jobs SET status='rejected',last_error=?,updated_at=? WHERE word=?",
                                (reason, now_iso(), word),
                            )
                        for word, reason in outcome.retry.items():
                            connection.execute(
                                "UPDATE jobs SET last_error=?,updated_at=? WHERE word=? AND status='pending'",
                                (reason, now_iso(), word),
                            )
                        connection.commit()
                        completed_batches += 1
                        if completed_batches % 20 == 0 or completed_batches == len(batches):
                            print(json.dumps(state_counts(connection), ensure_ascii=False), flush=True)
                        submit_next()
            except FatalAPIError:
                for future in future_map:
                    future.cancel()
                raise

        connection.execute(
            "UPDATE jobs SET status='quarantined',updated_at=? "
            "WHERE status='pending' AND attempts>=?",
            (now_iso(), arguments.max_attempts),
        )
        connection.commit()
    return state_counts(connection)


def strict_object_list_value(
    parsed: Any, required: tuple[str, ...]
) -> list[dict[str, str]] | None:
    """Mirror the app's strict `[String: String]` payload contract."""
    if not isinstance(parsed, list) or not parsed:
        return None
    result: list[dict[str, str]] = []
    for item in parsed:
        if not isinstance(item, dict) or not item:
            return None
        if any(not isinstance(key, str) or not isinstance(member, str) for key, member in item.items()):
            return None
        if any(not item.get(key, "").strip() for key in required):
            return None
        result.append(item)
    return result


def strict_json_object_list(
    value: str | None, required: tuple[str, ...]
) -> list[dict[str, str]] | None:
    try:
        parsed = json.loads(value or "[]")
    except (TypeError, json.JSONDecodeError):
        return None
    return strict_object_list_value(parsed, required)


REPAIRABLE_FIELDS = {"phonetic", "definitions", "phrases", "ielts_examples"}


def repair_fields_for_row(
    candidate: dict[str, Any], row: sqlite3.Row | tuple[Any, ...]
) -> set[str]:
    explicit = candidate.get("repair_fields")
    if explicit is not None:
        if (
            not isinstance(explicit, list)
            or not explicit
            or any(not isinstance(item, str) for item in explicit)
        ):
            raise RuntimeError(f"Invalid repair_fields for {candidate['word']}")
        fields = set(explicit)
        unknown = fields - REPAIRABLE_FIELDS
        if unknown:
            raise RuntimeError(
                f"Unknown repair_fields for {candidate['word']}: {sorted(unknown)}"
            )
        return fields

    # Compatibility for the already-generated v1 manifest/state: infer exactly
    # the structurally invalid columns, without rewriting valid legacy JSON.
    definitions, phrases, ielts = row[-3], row[-2], row[-1]
    fields: set[str] = set()
    if not strict_json_object_list(definitions, ("pos", "meaning", "example")):
        fields.add("definitions")
    if not strict_json_object_list(phrases, ("text", "meaning", "type")):
        fields.add("phrases")
    if not strict_json_object_list(ielts, ("sentence", "source")):
        fields.add("ielts_examples")
    if not fields:
        raise RuntimeError(
            f"Repair candidate {candidate['word']} has no invalid field and no repair_fields"
        )
    return fields


def content_authenticity_for_candidate(
    candidate: dict[str, Any], repaired_fields: set[str] | None = None
) -> str:
    """Choose the App's IELTS source label without overstating legacy content."""

    if (
        candidate.get("category") == "repair"
        and repaired_fields is not None
        and "ielts_examples" not in repaired_fields
    ):
        return "legacy_unverified"
    return "generated_style"


def create_expansion_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS word_metadata (
            word TEXT PRIMARY KEY,
            display_word TEXT NOT NULL,
            entry_type TEXT NOT NULL,
            lemma TEXT,
            provenance TEXT NOT NULL,
            content_authenticity TEXT NOT NULL,
            model TEXT,
            prompt_version TEXT,
            generated_at TEXT NOT NULL,
            FOREIGN KEY(word) REFERENCES words(word) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS word_aliases (
            alias TEXT PRIMARY KEY,
            lemma TEXT NOT NULL,
            display_word TEXT NOT NULL,
            form_type TEXT NOT NULL,
            provenance TEXT NOT NULL,
            generated_at TEXT NOT NULL,
            FOREIGN KEY(lemma) REFERENCES words(word) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_word_aliases_lemma ON word_aliases(lemma);
        CREATE TABLE IF NOT EXISTS expansion_runs (
            run_id TEXT PRIMARY KEY,
            model TEXT NOT NULL,
            prompt_version TEXT NOT NULL,
            candidates_sha256 TEXT NOT NULL,
            aliases_sha256 TEXT NOT NULL,
            started_at TEXT NOT NULL,
            published_at TEXT NOT NULL,
            success_count INTEGER NOT NULL,
            rejected_count INTEGER NOT NULL,
            quarantined_count INTEGER NOT NULL
        );
        """
    )
    timestamp = now_iso()
    connection.execute(
        """
        INSERT OR IGNORE INTO word_metadata(
            word,display_word,entry_type,lemma,provenance,content_authenticity,
            model,prompt_version,generated_at
        ) SELECT word,word,'legacy',word,'legacy-wordlist+deepseek','legacy_unverified',
                 NULL,'legacy',? FROM words
        """,
        (timestamp,),
    )


def validate_database(connection: sqlite3.Connection, expected_minimum: int) -> dict[str, int]:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"integrity_check failed: {integrity}")
    counts = {
        "words": connection.execute("SELECT COUNT(*) FROM words").fetchone()[0],
        "metadata": connection.execute("SELECT COUNT(*) FROM word_metadata").fetchone()[0],
        "aliases": connection.execute("SELECT COUNT(*) FROM word_aliases").fetchone()[0],
        "orphan_aliases": connection.execute(
            "SELECT COUNT(*) FROM word_aliases a LEFT JOIN words w ON w.word=a.lemma WHERE w.word IS NULL"
        ).fetchone()[0],
        "alias_collisions": connection.execute(
            "SELECT COUNT(*) FROM word_aliases a JOIN words w ON w.word=a.alias"
        ).fetchone()[0],
    }
    if counts["words"] < expected_minimum:
        raise RuntimeError("word count unexpectedly decreased")
    if counts["metadata"] != counts["words"]:
        raise RuntimeError("word_metadata does not cover every word")
    if counts["orphan_aliases"]:
        raise RuntimeError("word_aliases contains missing lemmas")
    if counts["alias_collisions"]:
        raise RuntimeError("word_aliases collides with direct word keys")

    errors: list[str] = []
    for word, definitions, phrases, ielts in connection.execute(
        "SELECT word,definitions,phrases,ielts_examples FROM words"
    ):
        if not isinstance(word, str) or normalize_word(word) != word:
            errors.append(f"{word}:non_normalized_key")
            if len(errors) >= 20:
                break
        for label, value, required in (
            ("definitions", definitions, ("pos", "meaning", "example")),
            ("phrases", phrases, ("text", "meaning", "type")),
            ("ielts_examples", ielts, ("sentence", "source")),
        ):
            items = strict_json_object_list(value, required)
            if not items:
                errors.append(f"{word}:{label}:empty_or_invalid")
                break
        if len(errors) >= 20:
            break
    if not errors:
        for alias, lemma in connection.execute(
            "SELECT alias,lemma FROM word_aliases ORDER BY alias"
        ):
            if normalize_word(alias) != alias or normalize_word(lemma) != lemma:
                errors.append(f"{alias}:non_normalized_alias")
                if len(errors) >= 20:
                    break
    if errors:
        raise RuntimeError("database content gate failed: " + ", ".join(errors))
    return counts


def sqlite_backup(source_path: Path, target_path: Path) -> None:
    source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    target = sqlite3.connect(target_path)
    source.backup(target)
    target.close()
    source.close()


def logical_words_hash(path: Path) -> tuple[int, str]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    digest = hashlib.sha256()
    count = 0
    for row in connection.execute(
        "SELECT word,phonetic,definitions,source,examples,phrases,ielts_examples "
        "FROM words ORDER BY word"
    ):
        digest.update(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
        count += 1
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    connection.close()
    if integrity != "ok":
        raise RuntimeError(f"integrity_check failed for {path}: {integrity}")
    return count, digest.hexdigest()


def ensure_no_sqlite_sidecars(path: Path) -> None:
    sidecars = [
        Path(f"{path}{suffix}")
        for suffix in ("-wal", "-shm", "-journal")
        if Path(f"{path}{suffix}").exists()
    ]
    if sidecars:
        raise RuntimeError(
            "Canonical database has active/stale SQLite sidecars: "
            + ", ".join(str(path) for path in sidecars)
        )


def publish_database(
    state: sqlite3.Connection,
    candidates: list[dict[str, Any]],
    aliases: list[dict[str, Any]],
    arguments: argparse.Namespace,
    run_id: str,
    state_counts_result: dict[str, int],
    expected_source_hash: str,
) -> tuple[Path, dict[str, int]]:
    arguments.backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    ensure_no_sqlite_sidecars(arguments.db)
    original_hash = sha256_file(arguments.db)
    if original_hash != expected_source_hash:
        raise RuntimeError("Canonical database changed before staging began")
    backup = arguments.backup_dir / f"words-before-expansion-{timestamp}-{original_hash[:10]}.db"
    sqlite_backup(arguments.db, backup)
    source_logical = logical_words_hash(arguments.db)
    backup_logical = logical_words_hash(backup)
    if backup_logical != source_logical:
        raise RuntimeError("verified SQLite backup does not logically match source")

    staging = arguments.db.with_name(f"{arguments.db.name}.next-{run_id}")
    if staging.exists():
        staging.unlink()
    sqlite_backup(arguments.db, staging)
    connection = sqlite3.connect(staging)
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA busy_timeout=5000")
    connection.row_factory = sqlite3.Row
    baseline_count = connection.execute("SELECT COUNT(*) FROM words").fetchone()[0]
    create_expansion_schema(connection)
    connection.execute("PRAGMA user_version=2")

    successful_payloads = {
        row[0]: json.loads(row[1])
        for row in state.execute("SELECT word,payload_json FROM jobs WHERE status='success'")
    }
    inserted_new = 0
    for candidate in candidates:
        word = normalize_word(candidate["word"])
        payload = successful_payloads.get(word)
        if payload is None:
            continue
        definitions = json.dumps(payload["definitions"], ensure_ascii=False, separators=(",", ":"))
        phrases = json.dumps(payload["phrases"], ensure_ascii=False, separators=(",", ":"))
        ielts = json.dumps(payload["ielts_examples"], ensure_ascii=False, separators=(",", ":"))
        examples = json.dumps(
            [item["example"] for item in payload["definitions"]],
            ensure_ascii=False,
            separators=(",", ":"),
        )
        existing = connection.execute(
            "SELECT phonetic,definitions,phrases,ielts_examples FROM words WHERE word=?",
            (word,),
        ).fetchone()
        repaired_fields: set[str] | None = None
        if existing is not None:
            if candidate.get("category") != "repair":
                raise RuntimeError(f"Non-repair candidate collides with existing word: {word}")
            repaired_fields = repair_fields_for_row(
                candidate,
                (existing["definitions"], existing["phrases"], existing["ielts_examples"]),
            )
            updates: dict[str, str] = {}
            if "phonetic" in repaired_fields:
                updates["phonetic"] = payload["phonetic"]
            if "definitions" in repaired_fields:
                updates["definitions"] = definitions
                updates["examples"] = examples
            if "phrases" in repaired_fields:
                updates["phrases"] = phrases
            if "ielts_examples" in repaired_fields:
                updates["ielts_examples"] = ielts
            assignments = ",".join(f"{column}=?" for column in updates)
            connection.execute(
                f"UPDATE words SET {assignments} WHERE word=?",
                (*updates.values(), word),
            )
        else:
            connection.execute(
                "INSERT INTO words(word,phonetic,definitions,source,examples,phrases,ielts_examples) "
                "VALUES (?,?,?,?,?,?,?)",
                (
                    word, payload["phonetic"], definitions, "deepseek-expansion-v5",
                    examples, phrases, ielts,
                ),
            )
            inserted_new += 1
        connection.execute(
            """
            INSERT INTO word_metadata(
                word,display_word,entry_type,lemma,provenance,content_authenticity,
                model,prompt_version,generated_at
            ) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(word) DO UPDATE SET
                display_word=excluded.display_word,entry_type=excluded.entry_type,
                lemma=excluded.lemma,provenance=excluded.provenance,
                content_authenticity=excluded.content_authenticity,model=excluded.model,
                prompt_version=excluded.prompt_version,generated_at=excluded.generated_at
            """,
            (
                word,
                payload["display_word"],
                payload["category"],
                payload["lemma"],
                json.dumps(payload["provenance"], ensure_ascii=False, separators=(",", ":")),
                content_authenticity_for_candidate(candidate, repaired_fields),
                arguments.model,
                PROMPT_VERSION,
                now_iso(),
            ),
        )

    # Aliases are a generated projection, so rebuild it exactly from the bound
    # manifest instead of retaining stale rows from an older expansion.
    connection.execute("DELETE FROM word_aliases")
    alias_rows = 0
    seen_aliases: set[str] = set()
    for alias in aliases:
        word = normalize_word(alias["word"])
        lemma = normalize_word(alias["lemma"])
        if word in seen_aliases:
            raise RuntimeError(f"Duplicate normalized alias in manifest: {word}")
        seen_aliases.add(word)
        if connection.execute("SELECT 1 FROM words WHERE word=?", (word,)).fetchone():
            raise RuntimeError(f"Alias collides with direct word: {word}")
        if not connection.execute("SELECT 1 FROM words WHERE word=?", (lemma,)).fetchone():
            raise RuntimeError(f"Alias lemma is missing: {word} -> {lemma}")
        connection.execute(
            """
            INSERT INTO word_aliases(alias,lemma,display_word,form_type,provenance,generated_at)
            VALUES (?,?,?,?,?,?)
            """,
            (
                word, lemma, alias.get("display_word", word), alias["form_type"],
                json.dumps(alias.get("provenance", []), ensure_ascii=False, separators=(",", ":")),
                now_iso(),
            ),
        )
        alias_rows += 1
    if alias_rows != len(aliases):
        raise RuntimeError(
            f"Alias rebuild count mismatch: wrote {alias_rows}, expected {len(aliases)}"
        )

    connection.execute(
        "INSERT OR REPLACE INTO expansion_runs VALUES (?,?,?,?,?,?,?,?,?,?)",
        (
            run_id, arguments.model, PROMPT_VERSION, sha256_file(arguments.candidates),
            sha256_file(arguments.aliases), now_iso(), now_iso(),
            state_counts_result.get("success", 0), state_counts_result.get("rejected", 0),
            state_counts_result.get("quarantined", 0),
        ),
    )
    connection.commit()
    quality = validate_database(connection, baseline_count + inserted_new)
    quality["inserted_new"] = inserted_new
    quality["aliases_written"] = alias_rows
    quality["excluded_nonrepair"] = (
        state_counts_result.get("quarantined", 0)
        + state_counts_result.get("rejected", 0)
    )
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    connection.execute("PRAGMA journal_mode=DELETE")
    connection.commit()
    connection.close()

    with staging.open("rb") as handle:
        os.fsync(handle.fileno())
    # Second compare-and-swap guard immediately before replacement. A writer
    # outside our advisory lock, or any WAL-backed mutation, aborts publishing.
    ensure_no_sqlite_sidecars(arguments.db)
    if sha256_file(arguments.db) != original_hash:
        raise RuntimeError("Canonical database changed while staging; publish aborted")
    if logical_words_hash(arguments.db) != source_logical:
        raise RuntimeError("Canonical database changed logically while staging; publish aborted")
    os.replace(staging, arguments.db)
    directory_fd = os.open(arguments.db.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return backup, quality


def main() -> int:
    arguments = parse_args()
    for path in (arguments.db, arguments.candidates, arguments.aliases, arguments.summary):
        if not path.is_file():
            raise SystemExit(f"Required file not found: {path}")
    if not 1 <= arguments.batch_size <= 12:
        raise SystemExit("--batch-size must be between 1 and 12")
    if not 1 <= arguments.workers <= 32:
        raise SystemExit("--workers must be between 1 and 32")
    validate_publish_scope(arguments)

    summary = validate_manifest_summary(
        arguments.summary, arguments.db, arguments.candidates, arguments.aliases
    )
    candidates = select_candidates(arguments)
    source_hash_at_start = sha256_file(arguments.db)
    selection_bytes = "\n".join(
        json.dumps(item, ensure_ascii=False, sort_keys=True) for item in candidates
    ).encode("utf-8")
    run_id = sha256_bytes(selection_bytes + PROMPT_VERSION.encode() + arguments.model.encode())[:16]
    state_path = arguments.run_dir / f"{run_id}.sqlite3"
    api_key, base_url = read_config()
    endpoint = endpoint_from_base(base_url)
    expected_state_metadata = {
        "aliases_sha256": sha256_file(arguments.aliases),
        "candidates_sha256": sha256_file(arguments.candidates),
        "endpoint": endpoint,
        "model": arguments.model,
        "prompt_version": PROMPT_VERSION,
        "selection_sha256": sha256_bytes(selection_bytes),
        "source_database_sha256": source_hash_at_start,
        "summary_sha256": sha256_file(arguments.summary),
        "validator_version": VALIDATOR_VERSION,
    }
    state = initialize_state(
        state_path,
        candidates,
        arguments.retry_quarantined,
        expected_state_metadata,
    )
    reused_successes = 0
    if arguments.reuse_state:
        if arguments.reuse_state.resolve() != state_path.resolve():
            reused_successes = import_compatible_successes(
                state, arguments.reuse_state, candidates
            )
    invalidated_successes = revalidate_state_successes(state, candidates)

    print(
        json.dumps(
            {
                "run_id": run_id,
                "selected": len(candidates),
                "model": arguments.model,
                "batch_size": arguments.batch_size,
                "workers": arguments.workers,
                "state": str(state_path),
                "reused_successes": reused_successes,
                "invalidated_successes": invalidated_successes,
                "manifest_schema_version": summary.get("schema_version"),
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    try:
        counts = run_generation(state, arguments, api_key, endpoint)
    except FatalAPIError as error:
        state.close()
        raise SystemExit(f"DeepSeek request stopped: {sanitize_error(error)}") from error

    print(json.dumps(counts, ensure_ascii=False, sort_keys=True), flush=True)
    gate = publishability(state)
    if gate["pending"] or gate["repair_not_success"] or gate["unexpected_status"]:
        state.close()
        raise SystemExit(
            "Run not publishable: "
            f"pending={gate['pending']}, repair_not_success={gate['repair_not_success']}, "
            f"unexpected_status={gate['unexpected_status']}; "
            f"resume with the same command or inspect {state_path}"
        )
    state.execute(
        "INSERT OR REPLACE INTO run_metadata(key,value) VALUES (?,?)",
        ("audit.excluded_nonrepair_count", str(gate["excluded_nonrepair"])),
    )
    state.commit()
    print(json.dumps({"publish_gate": gate}, ensure_ascii=False, sort_keys=True), flush=True)
    if arguments.no_publish:
        state.close()
        print("Generation completed; canonical database was not changed.")
        return 0

    aliases = load_jsonl(arguments.aliases)
    publish_lock_path = arguments.run_dir / "words-db-publish.lock"
    publish_lock_path.parent.mkdir(parents=True, exist_ok=True)
    with publish_lock_path.open("a+") as publish_lock:
        fcntl.flock(publish_lock.fileno(), fcntl.LOCK_EX)
        if sha256_file(arguments.db) != source_hash_at_start:
            state.close()
            raise SystemExit(
                "Canonical database changed during this run; rerun the same command to rebase safely"
            )
        backup, quality = publish_database(
            state,
            candidates,
            aliases,
            arguments,
            run_id,
            counts,
            source_hash_at_start,
        )
        fcntl.flock(publish_lock.fileno(), fcntl.LOCK_UN)
    state.close()
    print(
        json.dumps(
            {
                "published": str(arguments.db),
                "published_sha256": sha256_file(arguments.db),
                "backup": str(backup),
                "quality": quality,
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
