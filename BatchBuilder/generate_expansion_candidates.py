#!/usr/bin/env python3
"""Build a reproducible, quality-filtered expansion manifest for words.db.

The script never changes the dictionary database and never calls DeepSeek. It combines:
  * the current database (lemmas and rows needing repair),
  * macOS' public-domain Webster word lists and proper-name list,
  * exact full-term DictionaryServices matches,
  * lemminflect morphology, and
  * wordfreq ranking.

New lexical entries are written to one JSONL manifest. Legal inflected forms whose
lemma already exists are written to a separate alias manifest so they can reuse the
lemma's stored definitions/examples without thousands of redundant model calls.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

try:
    from lemminflect import getAllInflections, getAllLemmas
    from wordfreq import top_n_list, zipf_frequency
except ImportError as error:  # pragma: no cover - CLI preflight
    raise SystemExit(
        "Missing expansion dependencies. Run: "
        ".build/vocab-tools/bin/pip install -r BatchBuilder/requirements-expansion.txt"
    ) from error


PROJECT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_DB = PROJECT_DIR / "Resources" / "words.db"
DEFAULT_OUTPUT = PROJECT_DIR / "BatchBuilder" / "generated" / "expansion_candidates.jsonl"
DEFAULT_ALIASES = PROJECT_DIR / "BatchBuilder" / "generated" / "inflection_aliases.jsonl"
DEFAULT_SUMMARY = PROJECT_DIR / "BatchBuilder" / "generated" / "expansion_candidates.summary.json"
VALIDATOR_SOURCE = PROJECT_DIR / "BatchBuilder" / "dictionary_validate.swift"
VALIDATOR_BINARY = PROJECT_DIR / ".build" / "dictionary-validate"
LOCALE_SOURCE = PROJECT_DIR / "BatchBuilder" / "locale_proper_names.swift"
LOCALE_BINARY = PROJECT_DIR / ".build" / "locale-proper-names"
WEB2_PATH = Path("/usr/share/dict/web2")
PROPER_NAMES_PATH = Path("/usr/share/dict/propernames")

WORD_PATTERN = re.compile(r"^[a-z][a-z'-]{1,39}$")
TERM_PATTERN = re.compile(r"^[^\W\d_]+(?:[ '\-][^\W\d_]+)*$", re.UNICODE)
INFLECTION_PATTERN = re.compile(r"^[a-z]{2,32}$")
PROMOTE_AMBIGUOUS_MIN_ZIPF = 2.0
GENERAL_GAP_MIN_ZIPF = 3.35
APOSTROPHELESS_CONTRACTIONS = {
    "aint",
    "arent",
    "couldnt",
    "didnt",
    "doesnt",
    "dont",
    "hadnt",
    "hasnt",
    "havent",
    "isnt",
    "mightnt",
    "mustnt",
    "neednt",
    "shouldnt",
    "theyre",
    "theyve",
    "wasnt",
    "werent",
    "weve",
    "wouldnt",
    "youre",
    "youve",
}
GENERIC_LOCALE_TERMS = {
    "multiple languages",
    "unknown language",
    "world",
}
KNOWN_UPPERCASE_ABBREVIATIONS = {"ama", "obe", "vod"}
CJK_DCS_FALSE_HEADWORD_HITS = {
    "aba", "ala", "anda", "ati", "bahama", "bala", "bali", "banda", "bianchi",
    "bibi", "bute", "chang", "chao", "che", "cheng", "chun", "dae", "dali",
    "dao", "fei", "ganga", "gen", "ger", "hainan", "hala", "han", "hao", "hei",
    "hulu", "jing", "kan", "kang", "ker", "kuan", "liang", "lilian", "lise",
    "mala", "mang", "mao", "masha", "meng", "mou", "napa", "nar", "pala",
    "quan", "rishi", "sai", "sao", "sha", "shang", "sheng", "shi", "shou",
    "sisi", "tou", "tui", "yan",
}
MANUAL_INDEPENDENT_INFLECTED_LEXEMES = {"biting", "fading", "guiding", "shouting"}
LOCALE_SUBTYPE = {
    "Apple/CLDR:ISO-region": "region_name",
    "Apple/CLDR:ISO-language": "language_name",
    "Apple/CLDR:time-zone": "place_name",
}
TYPE_PRIORITY = {
    "plural": 0,
    "past": 1,
    "past_participle": 2,
    "present_participle": 3,
    "third_person_singular": 4,
    "comparative": 5,
    "superlative": 6,
}
TAG_TO_FORM = {
    "NNS": "plural",
    "VBD": "past",
    "VBN": "past_participle",
    "VBG": "present_participle",
    "VBZ": "third_person_singular",
    "JJR": "comparative",
    "JJS": "superlative",
    "RBR": "comparative",
    "RBS": "superlative",
}
POS_TO_UPOS = {
    "noun": "NOUN",
    "verb": "VERB",
    "adjective": "ADJ",
    "adverb": "ADV",
}
FORM_TO_REVERSE_POS = {
    "plural": {"NOUN"},
    "past": {"VERB", "AUX"},
    "past_participle": {"VERB", "AUX"},
    "present_participle": {"VERB", "AUX"},
    "third_person_singular": {"VERB", "AUX"},
    "comparative": {"ADJ", "ADV"},
    "superlative": {"ADJ", "ADV"},
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--aliases-output", type=Path, default=DEFAULT_ALIASES)
    parser.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument("--proper-limit", type=int, default=2_500)
    parser.add_argument("--general-limit", type=int, default=1_200)
    parser.add_argument("--rare-limit", type=int, default=2_500)
    parser.add_argument("--wordfreq-size", type=int, default=250_000)
    return parser.parse_args()


def normalize_word(value: str) -> str:
    value = unicodedata.normalize("NFKC", value.strip())
    value = value.replace("’", "'").replace("‘", "'").replace("ʼ", "'")
    for character in "‐‑‒–—−－":
        value = value.replace(character, "-")
    return value.lower()


def atomic_write_text(path: Path, content: str) -> None:
    """Atomically replace one manifest file and durably sync file + directory."""

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fchmod(handle.fileno(), 0o644)
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(value: str | None) -> Any:
    try:
        return json.loads(value or "[]")
    except (TypeError, json.JSONDecodeError):
        return None


def valid_object_list(value: str | None, required: tuple[str, ...]) -> bool:
    parsed = load_json(value)
    if not isinstance(parsed, list) or not parsed:
        return False
    for item in parsed:
        if not isinstance(item, dict):
            return False
        for key in required:
            member = item.get(key)
            if not isinstance(member, str) or not member.strip():
                return False
    return True


def valid_ielts_list(value: str | None) -> bool:
    parsed = load_json(value)
    if not isinstance(parsed, list) or not parsed:
        return False
    for item in parsed:
        if not isinstance(item, dict):
            return False
        sentence = item.get("sentence")
        source = item.get("source")
        year = item.get("year")
        if not isinstance(sentence, str) or not sentence.strip():
            return False
        if not isinstance(source, str) or not source.strip():
            return False
        if year is not None and not isinstance(year, str):
            return False
    return True


def row_needs_repair(definitions: str | None, phrases: str | None, ielts: str | None) -> bool:
    return not (
        valid_object_list(definitions, ("pos", "meaning", "example"))
        and valid_object_list(phrases, ("text", "meaning", "type"))
        and valid_ielts_list(ielts)
    )


def repair_fields(
    definitions: str | None, phrases: str | None, ielts: str | None
) -> list[str]:
    fields: list[str] = []
    if not valid_object_list(definitions, ("pos", "meaning", "example")):
        fields.append("definitions")
    if not valid_object_list(phrases, ("text", "meaning", "type")):
        fields.append("phrases")
    if not valid_ielts_list(ielts):
        fields.append("ielts_examples")
    return fields


def definition_parts_of_speech(definitions: str | None) -> set[str]:
    parsed = load_json(definitions)
    if isinstance(parsed, dict):
        parsed = [parsed]
    if not isinstance(parsed, list):
        return set()

    result: set[str] = set()
    for item in parsed:
        if not isinstance(item, dict):
            continue
        value = str(item.get("pos", "")).lower()
        if "noun" in value or re.search(r"(^|[/ ])n\.", value):
            result.add("noun")
        if "verb" in value or re.search(r"(^|[/ ])v\.", value):
            result.add("verb")
        if "adjective" in value or "adj." in value:
            result.add("adjective")
        if "adverb" in value or "adv." in value:
            result.add("adverb")
    return result


def compile_swift_helper(source: Path, binary: Path) -> Path:
    binary.parent.mkdir(parents=True, exist_ok=True)
    rebuild = (
        not binary.exists()
        or binary.stat().st_mtime < source.stat().st_mtime
    )
    if rebuild:
        command = ["swiftc", str(source), "-o", str(binary)]
        completed = subprocess.run(command, text=True, capture_output=True)
        if completed.returncode:
            message = completed.stderr.strip() or completed.stdout.strip()
            raise SystemExit(f"Could not compile Swift helper {source.name}: {message}")
    return binary


def compile_validator() -> Path:
    return compile_swift_helper(VALIDATOR_SOURCE, VALIDATOR_BINARY)


def load_locale_terms() -> list[dict[str, str]]:
    binary = compile_swift_helper(LOCALE_SOURCE, LOCALE_BINARY)
    completed = subprocess.run([str(binary)], text=True, capture_output=True)
    if completed.returncode:
        raise SystemExit(f"Locale term helper failed: {completed.stderr.strip()}")
    rows: list[dict[str, str]] = []
    for line in completed.stdout.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict) and isinstance(item.get("displayWord"), str):
            rows.append(item)
    return rows


def dictionary_matches(
    words: Iterable[str], validator: Path, *, require_english_headword: bool = False
) -> set[str]:
    ordered = sorted(set(words))
    if not ordered:
        return set()
    command = [str(validator)]
    if require_english_headword:
        command.append("--english-headword")
    completed = subprocess.run(
        command,
        input="\n".join(ordered) + "\n",
        text=True,
        capture_output=True,
    )
    if completed.returncode:
        raise SystemExit(f"DictionaryServices validator failed: {completed.stderr.strip()}")
    return {line.strip() for line in completed.stdout.splitlines() if line.strip()}


def load_dictionary_rows(db_path: Path) -> tuple[dict[str, dict[str, Any]], list[dict[str, Any]]]:
    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    rows: dict[str, dict[str, Any]] = {}
    repairs: list[dict[str, Any]] = []
    for row in connection.execute(
        "SELECT word, definitions, phrases, ielts_examples FROM words ORDER BY word"
    ):
        raw_word = str(row["word"])
        word = normalize_word(raw_word)
        if not word:
            raise SystemExit(f"Database contains an empty normalized word key: {raw_word!r}")
        if word in rows:
            raise SystemExit(
                "Database contains a normalized-key collision: "
                f"{raw_word!r} and another row both normalize to {word!r}"
            )
        record = {
            "definitions": row["definitions"],
            "phrases": row["phrases"],
            "ielts_examples": row["ielts_examples"],
            "parts_of_speech": definition_parts_of_speech(row["definitions"]),
        }
        rows[word] = record
        fields = repair_fields(row["definitions"], row["phrases"], row["ielts_examples"])
        if fields:
            repairs.append(
                {
                    "word": word,
                    "display_word": raw_word,
                    "category": "repair",
                    "lemma": word,
                    "score": round(zipf_frequency(word, "en"), 3),
                    "provenance": ["words.db:incomplete_legacy_row"],
                    "repair_fields": fields,
                }
            )
    connection.close()
    return rows, repairs


def generate_inflections(
    rows: dict[str, dict[str, Any]],
    validator: Path,
    web2_forms: dict[str, set[str]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    """Return safe aliases, promoted ambiguous lexemes, and inspectable audit data.

    DictionaryServices is only a supplemental exact-term check. English evidence
    comes from an existing English lemma plus lemminflect's forward/reverse
    morphology (and, for promoted lexemes, non-zero English corpus frequency).
    This prevents an exact hit in an installed CJK dictionary from being treated
    as proof that a romanized string is an English headword.
    """

    proposed: dict[str, list[dict[str, Any]]] = defaultdict(list)
    existing = set(rows)

    for lemma, record in rows.items():
        if not INFLECTION_PATTERN.fullmatch(lemma):
            continue
        all_lemmas = getAllLemmas(lemma)
        for pos in sorted(record["parts_of_speech"]):
            upos = POS_TO_UPOS[pos]
            # Only expand a true lemma. This prevents treating "walked" as a new base.
            if lemma not in all_lemmas.get(upos, ()):
                continue
            for tag, forms in getAllInflections(lemma, upos=upos).items():
                form_type = TAG_TO_FORM.get(tag)
                if form_type is None:
                    continue
                for raw_form in forms:
                    form = normalize_word(raw_form)
                    if (
                        form == lemma
                        or form in existing
                        or not INFLECTION_PATTERN.fullmatch(form)
                    ):
                        continue
                    proposed[form].append(
                        {
                            "word": form,
                            "display_word": form,
                            "lemma": lemma,
                            "form_type": form_type,
                            "source_pos": upos,
                            "score": round(zipf_frequency(form, "en"), 3),
                            "provenance": [
                                "lemminflect:0.2.3:forward-and-reverse",
                                "macOS:DictionaryServices:supplemental-exact-term",
                            ],
                        }
                    )

    accepted = dictionary_matches(proposed, validator)
    independent_english_headwords = dictionary_matches(
        proposed, validator, require_english_headword=True
    )
    aliases: list[dict[str, Any]] = []
    promoted: list[dict[str, Any]] = []
    quarantined: list[dict[str, Any]] = []
    filtered_contractions: list[str] = []
    retained_zero_score: list[str] = []
    filtered_zero_score: list[dict[str, str]] = []

    for form in sorted(accepted):
        # Collapse duplicate forward analyses but never pick one lemma merely by
        # frequency. A many-lemma form needs its own dictionary entry or quarantine.
        unique_options = {
            (item["lemma"], item["form_type"], item["source_pos"]): item
            for item in proposed[form]
        }
        options = sorted(
            unique_options.values(),
            key=lambda item: (
                -zipf_frequency(item["lemma"], "en"),
                TYPE_PRIORITY[item["form_type"]],
                len(item["lemma"]),
                item["lemma"],
            ),
        )
        score = round(zipf_frequency(form, "en"), 3)
        if form in APOSTROPHELESS_CONTRACTIONS:
            filtered_contractions.append(form)
            if score == 0:
                filtered_zero_score.append(
                    {"word": form, "reason": "apostropheless_contraction"}
                )
            continue

        proposed_lemmas = {item["lemma"] for item in options}
        reverse = getAllLemmas(form)
        reverse_lemmas = {
            normalize_word(lemma)
            for lemmas in reverse.values()
            for lemma in lemmas
            if normalize_word(lemma)
        }

        selected = options[0]
        selected_lemma = selected["lemma"]
        expected_reverse = FORM_TO_REVERSE_POS[selected["form_type"]]
        selected_in_expected_pos = any(
            selected_lemma in {normalize_word(lemma) for lemma in reverse.get(pos, ())}
            for pos in expected_reverse
        )
        reasons: list[str] = []
        if len(proposed_lemmas) > 1:
            reasons.append("multiple_forward_lemmas")
        if form in reverse_lemmas:
            reasons.append("independent_lemma")
        if form in independent_english_headwords:
            reasons.append("independent_dictionary_headword")
        if form in MANUAL_INDEPENDENT_INFLECTED_LEXEMES:
            reasons.append("manual_independent_lexeme_audit")
        if reverse_lemmas - {selected_lemma}:
            reasons.append("multiple_reverse_lemmas")
        if not selected_in_expected_pos:
            reasons.append("reverse_analysis_mismatch")

        if reasons:
            audit_item = {
                "word": form,
                "score": score,
                "reasons": sorted(set(reasons)),
                "candidate_lemmas": sorted(proposed_lemmas | reverse_lemmas),
            }
            if score >= PROMOTE_AMBIGUOUS_MIN_ZIPF:
                provenance = [
                    "lemminflect:0.2.3:ambiguous-inflection",
                    "wordfreq:3.1.1:English-corpus",
                ]
                if form in independent_english_headwords:
                    provenance.append("macOS:DictionaryServices:English-headword")
                else:
                    provenance.append(
                        "macOS:DictionaryServices:supplemental-exact-term"
                    )
                if form in web2_forms:
                    provenance.append("macOS:web2:English-word-list")
                promoted.append(
                    {
                        "word": form,
                        "display_word": form,
                        "category": (
                            "general_gap"
                            if score >= GENERAL_GAP_MIN_ZIPF
                            else "inflected_lexeme"
                        ),
                        "promoted_direct_type": (
                            "independent_inflected_lexeme"
                            if form in MANUAL_INDEPENDENT_INFLECTED_LEXEMES
                            else "ambiguous_inflected_lexeme"
                        ),
                        "lemma": form,
                        "score": score,
                        "provenance": provenance,
                        "promotion_reason": audit_item["reasons"],
                        "candidate_lemmas": audit_item["candidate_lemmas"],
                    }
                )
                if form in MANUAL_INDEPENDENT_INFLECTED_LEXEMES:
                    promoted[-1]["provenance"].append(
                        "manual-audit:independent-noun-or-adjective-sense"
                    )
            else:
                quarantined.append(audit_item)
                if score == 0:
                    filtered_zero_score.append(
                        {"word": form, "reason": "low-frequency-ambiguous-form"}
                    )
            continue

        selected["score"] = score
        selected.pop("source_pos", None)
        if score == 0:
            retained_zero_score.append(form)
        aliases.append(selected)

    audit = {
        "promoted_direct": sorted(item["word"] for item in promoted),
        "manual_independent_inflected_lexemes": sorted(
            item["word"]
            for item in promoted
            if item.get("promoted_direct_type") == "independent_inflected_lexeme"
        ),
        "quarantined_ambiguous": quarantined,
        "filtered_apostropheless_contractions": sorted(filtered_contractions),
        "retained_zero_score": sorted(retained_zero_score),
        "filtered_zero_score": sorted(filtered_zero_score, key=lambda item: item["word"]),
    }
    return (
        sorted(aliases, key=lambda item: item["word"]),
        sorted(promoted, key=lambda item: item["word"]),
        audit,
    )


def read_word_lists() -> tuple[dict[str, set[str]], list[str]]:
    if not WEB2_PATH.exists() or not PROPER_NAMES_PATH.exists():
        raise SystemExit("Required macOS word lists were not found under /usr/share/dict")

    web2_forms: dict[str, set[str]] = defaultdict(set)
    for line in WEB2_PATH.read_text(encoding="utf-8", errors="replace").splitlines():
        original = unicodedata.normalize("NFC", line.strip())
        word = normalize_word(original)
        if WORD_PATTERN.fullmatch(word):
            web2_forms[word].add(original)

    proper_names = [
        line.strip()
        for line in PROPER_NAMES_PATH.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.strip()
    ]
    return web2_forms, proper_names


def choose_direct_candidates(
    rows: dict[str, dict[str, Any]],
    repairs: list[dict[str, Any]],
    aliases: list[dict[str, Any]],
    promoted: list[dict[str, Any]],
    validator: Path,
    web2_forms: dict[str, set[str]],
    proper_names: list[str],
    proper_limit: int,
    general_limit: int,
    rare_limit: int,
    wordfreq_size: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    existing = set(rows)
    alias_words = {item["word"] for item in aliases}
    promoted_words = {item["word"] for item in promoted}
    lowercase_web2 = {
        word
        for word, forms in web2_forms.items()
        if any(form == form.lower() for form in forms)
    }

    missing_web2 = set(web2_forms) - existing - alias_words - promoted_words
    blocked_contractions = missing_web2 & APOSTROPHELESS_CONTRACTIONS
    missing_web2 -= blocked_contractions
    exact_web2 = dictionary_matches(
        missing_web2, validator, require_english_headword=True
    )
    frequency_rank = {
        word: index for index, word in enumerate(top_n_list("en", wordfreq_size, ascii_only=True))
    }

    selected: set[str] = set(promoted_words)
    filtered_contractions: list[str] = sorted(blocked_contractions)
    filtered_locale_terms: list[dict[str, str]] = []
    filtered_zero_score: list[dict[str, str]] = []
    retained_zero_score: list[dict[str, str]] = [
        {"word": item["word"], "reason": "repair-existing-row"}
        for item in repairs
        if item["score"] == 0
    ]

    # Only semantically typed Apple/CLDR entries and the system personal-name list
    # can establish a proper-name candidate. Capitalization in Webster alone cannot:
    # many adjectives and common nouns are capitalized in historical entries.
    proper_options: dict[str, dict[str, Any]] = {}

    def add_proper_option(
        *, display: str, source: str, subtype: str, priority: int
    ) -> None:
        word = normalize_word(display)
        if (
            word in existing
            or word in alias_words
            or word in promoted_words
            or not TERM_PATTERN.fullmatch(word)
        ):
            return
        if word in APOSTROPHELESS_CONTRACTIONS:
            filtered_contractions.append(word)
            return
        if word in GENERIC_LOCALE_TERMS:
            filtered_locale_terms.append({"word": word, "reason": "generic-placeholder"})
            return
        # A typed CLDR/name source is real evidence even when the spelling also
        # has a lowercase adjective/common sense (Georgia, Slovak, Rose, Mobile).
        # Keep it, but mark it as a named lexeme so content generation must cover
        # both the named sense and ordinary lexical senses instead of forcing a
        # proper-noun-only entry. Capitalized Webster entries without a typed
        # source never reach this function.
        is_named_lexeme = word in lowercase_web2

        score = round(zipf_frequency(word, "en"), 3)
        # Zero-corpus CLDR geographic/language identifiers remain useful rare
        # proper names. An unobserved name from the much broader personal-name
        # lexicon is too low-value to spend a model call on.
        if score == 0 and source == "macOS:/usr/share/dict/propernames":
            filtered_zero_score.append(
                {"word": word, "reason": "unobserved-system-personal-name"}
            )
            return

        current = proper_options.get(word)
        if current is None:
            proper_options[word] = {
                "word": word,
                "display_word": display,
                "category": "proper_noun",
                "lemma": word,
                "score": score,
                "provenance": [source],
                "subtype": subtype,
                "proper_subtypes": [subtype],
                "proper_priority": priority,
                "display_priority": priority,
            }
            if is_named_lexeme:
                proper_options[word]["promoted_direct_type"] = "typed_named_lexeme"
                proper_options[word]["lexical_ambiguity"] = True
                proper_options[word]["provenance"].append(
                    "macOS:web2:lowercase-English-lexeme"
                )
        else:
            if source not in current["provenance"]:
                current["provenance"].append(source)
            if subtype not in current["proper_subtypes"]:
                current["proper_subtypes"].append(subtype)
            current["proper_subtypes"].sort()
            current["proper_priority"] = min(current["proper_priority"], priority)
            if priority < current["display_priority"]:
                current["display_word"] = display
                current["subtype"] = subtype
                current["display_priority"] = priority
            if is_named_lexeme:
                current["promoted_direct_type"] = "typed_named_lexeme"
                current["lexical_ambiguity"] = True
                if "macOS:web2:lowercase-English-lexeme" not in current["provenance"]:
                    current["provenance"].append(
                        "macOS:web2:lowercase-English-lexeme"
                    )

    for item in load_locale_terms():
        display = item["displayWord"].strip()
        source = item.get("source", "")
        subtype = LOCALE_SUBTYPE.get(source)
        if subtype is None:
            filtered_locale_terms.append(
                {"word": normalize_word(display), "reason": "unknown-CLDR-source"}
            )
            continue
        add_proper_option(display=display, source=source, subtype=subtype, priority=-1)

    for display in proper_names:
        if not WORD_PATTERN.fullmatch(normalize_word(display)):
            continue
        add_proper_option(
            display=display,
            source="macOS:/usr/share/dict/propernames",
            subtype="personal_name",
            priority=0,
        )

    proper = sorted(
        proper_options.values(),
        key=lambda item: (
            item["proper_priority"],
            frequency_rank.get(item["word"], wordfreq_size + 1),
            -item["score"],
            item["word"],
        ),
    )[:proper_limit]
    for item in proper:
        item.pop("proper_priority", None)
        item.pop("display_priority", None)
        item["provenance"] = sorted(set(item["provenance"]))
        if item["score"] == 0:
            retained_zero_score.append(
                {"word": item["word"], "reason": "typed-CLDR-proper-name"}
            )
        selected.add(item["word"])

    pool: list[dict[str, Any]] = []
    for word in exact_web2:
        if word in selected or len(word) < 3:
            continue
        if word in APOSTROPHELESS_CONTRACTIONS:
            filtered_contractions.append(word)
            if zipf_frequency(word, "en") == 0:
                filtered_zero_score.append(
                    {"word": word, "reason": "apostropheless-contraction"}
                )
            continue
        score = zipf_frequency(word, "en")
        item: dict[str, Any] = {
            "word": word,
            "display_word": word,
            "lemma": word,
            "score": round(score, 3),
            "provenance": [
                "macOS:web2:English-word-list",
                "macOS:DictionaryServices:English-headword",
                "wordfreq:3.1.1:English-corpus",
            ],
        }
        if word in KNOWN_UPPERCASE_ABBREVIATIONS:
            item["display_word"] = word.upper()
            item["subtype"] = "abbreviation"
            item["provenance"].append(
                "manual-audit:DCS-English-abbreviation-headword"
            )
        pool.append(item)

    # Fill the largest practical holes first: recognized, high-frequency words that
    # were absent from the original 27k list.
    general_pool = [item for item in pool if item["score"] >= GENERAL_GAP_MIN_ZIPF]
    general = sorted(general_pool, key=lambda item: (-item["score"], item["word"]))[
        :general_limit
    ]
    for item in general:
        item["category"] = "general_gap"
        selected.add(item["word"])

    # Then sample genuinely uncommon but currently recognized dictionary terms.
    # Corpus frequency orders usefulness; deterministic alphabetic tie-breaking keeps
    # the manifest stable across reruns with the same dependencies.
    rare_pool = [
        item
        for item in pool
        if item["word"] not in selected and item["score"] < GENERAL_GAP_MIN_ZIPF
    ]
    rare = sorted(rare_pool, key=lambda item: (-item["score"], item["word"]))[:rare_limit]
    for item in rare:
        item["category"] = "rare_word"
        selected.add(item["word"])

    selected_rare = {item["word"] for item in rare}
    for item in pool:
        if item["score"] == 0 and item["word"] not in selected_rare:
            filtered_zero_score.append(
                {"word": item["word"], "reason": "below-rare-word-selection-limit"}
            )

    category_order = {
        "repair": 0,
        "general_gap": 1,
        "inflected_lexeme": 2,
        "proper_noun": 3,
        "rare_word": 4,
    }
    direct = repairs + promoted + general + proper + rare
    direct = sorted(direct, key=lambda item: (category_order[item["category"]], item["word"]))
    untyped_cjk_regressions = sorted(
        item["word"]
        for item in direct
        if item["word"] in CJK_DCS_FALSE_HEADWORD_HITS
        and item["category"] in {"general_gap", "inflected_lexeme", "rare_word"}
    )
    if untyped_cjk_regressions:
        raise SystemExit(
            "English-headword regression: CJK DCS false hits entered the untyped "
            f"direct pool: {untyped_cjk_regressions}"
        )
    audit = {
        "english_headword_gate": {
            "candidate_pool_count": len(missing_web2),
            "accepted_count": len(exact_web2),
            "validator_mode": "--english-headword",
            "rule": (
                "DCS exact range plus definition-prefix headword equality; "
                "CJK/pinyin DCS hits are rejected"
            ),
        },
        "filtered_apostropheless_contractions": sorted(set(filtered_contractions)),
        "filtered_locale_terms": sorted(
            {json.dumps(item, sort_keys=True): item for item in filtered_locale_terms}.values(),
            key=lambda item: (item["word"], item["reason"]),
        ),
        "promoted_typed_named_lexemes": sorted(
            item["word"]
            for item in direct
            if item.get("promoted_direct_type") == "typed_named_lexeme"
        ),
        "audited_uppercase_abbreviations": sorted(
            item["word"] for item in direct if item.get("subtype") == "abbreviation"
        ),
        "cjk_false_headword_regression": {
            "expected_rejected_count": len(CJK_DCS_FALSE_HEADWORD_HITS),
            "untyped_direct_survivors": untyped_cjk_regressions,
            "typed_named_lexemes_allowed": sorted(
                item["word"]
                for item in direct
                if item["word"] in CJK_DCS_FALSE_HEADWORD_HITS
                and item.get("promoted_direct_type") == "typed_named_lexeme"
            ),
        },
        "retained_zero_score": sorted(retained_zero_score, key=lambda item: item["word"]),
        "filtered_zero_score": sorted(
            {json.dumps(item, sort_keys=True): item for item in filtered_zero_score}.values(),
            key=lambda item: (item["word"], item["reason"]),
        ),
    }
    return direct, audit


def validate_manifests(
    rows: dict[str, dict[str, Any]],
    direct: list[dict[str, Any]],
    aliases: list[dict[str, Any]],
) -> None:
    def normalized_keys(items: list[dict[str, Any]], label: str) -> list[str]:
        keys: list[str] = []
        originals: dict[str, str] = {}
        for index, item in enumerate(items, 1):
            raw = item.get("word")
            if not isinstance(raw, str) or not raw.strip():
                raise SystemExit(f"{label} row {index} has no word")
            key = normalize_word(raw)
            if raw != key:
                raise SystemExit(
                    f"{label} word must already be normalized: {raw!r} -> {key!r}"
                )
            if key in originals:
                raise SystemExit(
                    f"{label} normalized collision: {originals[key]!r} and {raw!r}"
                )
            originals[key] = raw
            keys.append(key)
        return keys

    direct_keys = normalized_keys(direct, "direct manifest")
    alias_keys = normalized_keys(aliases, "alias manifest")
    overlap = set(direct_keys) & set(alias_keys)
    if overlap:
        raise SystemExit(f"Direct/alias manifests overlap: {sorted(overlap)[:20]}")

    for item in direct:
        word = item["word"]
        category = item.get("category")
        if category == "repair":
            fields = item.get("repair_fields")
            if word not in rows or not isinstance(fields, list) or not fields:
                raise SystemExit(f"Invalid repair candidate: {word}")
        elif word in rows:
            raise SystemExit(f"New direct candidate already exists in words.db: {word}")
        if category == "proper_noun" and not item.get("subtype"):
            raise SystemExit(f"Proper-name candidate lacks subtype: {word}")
        promoted_type = item.get("promoted_direct_type")
        if promoted_type in {
            "ambiguous_inflected_lexeme",
            "independent_inflected_lexeme",
        } and category not in {
            "general_gap",
            "inflected_lexeme",
        }:
            raise SystemExit(f"Promoted inflection has invalid category: {word}")
        if promoted_type == "typed_named_lexeme" and category != "proper_noun":
            raise SystemExit(f"Typed named lexeme has invalid category: {word}")

    for item in aliases:
        if item.get("lemma") not in rows:
            raise SystemExit(f"Alias lemma is absent from words.db: {item['word']}")


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    content = "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows
    )
    atomic_write_text(path, content)


def main() -> int:
    arguments = parse_args()
    if not arguments.db.is_file():
        raise SystemExit(f"Database not found: {arguments.db}")

    validator = compile_validator()
    rows, repairs = load_dictionary_rows(arguments.db)
    web2_forms, proper_names = read_word_lists()
    aliases, promoted, inflection_audit = generate_inflections(
        rows, validator, web2_forms
    )
    direct, direct_audit = choose_direct_candidates(
        rows,
        repairs,
        aliases,
        promoted,
        validator,
        web2_forms,
        proper_names,
        arguments.proper_limit,
        arguments.general_limit,
        arguments.rare_limit,
        arguments.wordfreq_size,
    )

    validate_manifests(rows, direct, aliases)
    write_jsonl(arguments.output, direct)
    write_jsonl(arguments.aliases_output, aliases)

    category_counts: dict[str, int] = defaultdict(int)
    for item in direct:
        category_counts[item["category"]] += 1
    form_counts: dict[str, int] = defaultdict(int)
    for item in aliases:
        form_counts[item["form_type"]] += 1
    subtype_counts: dict[str, int] = defaultdict(int)
    repair_field_counts: dict[str, int] = defaultdict(int)
    for item in direct:
        if item.get("category") == "proper_noun":
            subtype_counts[item["subtype"]] += 1
        for field in item.get("repair_fields", []):
            repair_field_counts[field] += 1

    promoted_words = inflection_audit["promoted_direct"]
    retained_zero = (
        [
            {"word": word, "reason": "unique-legal-inflection-alias"}
            for word in inflection_audit["retained_zero_score"]
        ]
        + direct_audit["retained_zero_score"]
    )
    filtered_zero = (
        inflection_audit["filtered_zero_score"]
        + direct_audit["filtered_zero_score"]
    )
    filtered_contractions = sorted(
        set(inflection_audit["filtered_apostropheless_contractions"])
        | set(direct_audit["filtered_apostropheless_contractions"])
    )

    summary = {
        "schema_version": 2,
        "database": str(arguments.db.resolve()),
        "database_sha256": sha256(arguments.db),
        "database_rows": len(rows),
        "direct_candidates": len(direct),
        "direct_categories": dict(sorted(category_counts.items())),
        "proper_subtypes": dict(sorted(subtype_counts.items())),
        "repair_fields": dict(sorted(repair_field_counts.items())),
        "inflection_aliases": len(aliases),
        "inflection_forms": dict(sorted(form_counts.items())),
        "quality_audit": {
            "promoted_direct": {
                "count": len(promoted_words),
                "words": promoted_words,
            },
            "manual_independent_inflected_lexemes": {
                "count": len(
                    inflection_audit["manual_independent_inflected_lexemes"]
                ),
                "words": inflection_audit["manual_independent_inflected_lexemes"],
                "reason": "independent noun/adjective sense missed by DCS language collision",
            },
            "promoted_typed_named_lexemes": {
                "count": len(direct_audit["promoted_typed_named_lexemes"]),
                "words": direct_audit["promoted_typed_named_lexemes"],
            },
            "audited_uppercase_abbreviations": {
                "count": len(direct_audit["audited_uppercase_abbreviations"]),
                "words": direct_audit["audited_uppercase_abbreviations"],
            },
            "quarantined_ambiguous_inflections": {
                "count": len(inflection_audit["quarantined_ambiguous"]),
                "items": inflection_audit["quarantined_ambiguous"],
            },
            "filtered_apostropheless_contractions": {
                "count": len(filtered_contractions),
                "words": filtered_contractions,
            },
            "filtered_locale_terms": {
                "count": len(direct_audit["filtered_locale_terms"]),
                "items": direct_audit["filtered_locale_terms"],
            },
            "english_headword_gate": direct_audit["english_headword_gate"],
            "cjk_false_headword_regression": direct_audit[
                "cjk_false_headword_regression"
            ],
            "retained_zero_score": {
                "count": len(retained_zero),
                "items": sorted(retained_zero, key=lambda item: item["word"]),
            },
            "filtered_zero_score": {
                "count": len(filtered_zero),
                "items": sorted(
                    filtered_zero, key=lambda item: (item["word"], item["reason"])
                ),
            },
        },
        "selection": {
            "proper_limit": arguments.proper_limit,
            "general_limit": arguments.general_limit,
            "rare_limit": arguments.rare_limit,
            "wordfreq_size": arguments.wordfreq_size,
            "general_gap_min_zipf": GENERAL_GAP_MIN_ZIPF,
            "promote_ambiguous_min_zipf": PROMOTE_AMBIGUOUS_MIN_ZIPF,
        },
        "sources": {
            "web2": str(WEB2_PATH),
            "web2_sha256": sha256(WEB2_PATH),
            "propernames": str(PROPER_NAMES_PATH),
            "propernames_sha256": sha256(PROPER_NAMES_PATH),
            "wordfreq": "3.1.1",
            "lemminflect": "0.2.3",
            "dictionary_services": platform.mac_ver()[0],
            "dictionary_services_role": (
                "default exact-term mode is supplemental only; --english-headword "
                "mode is required for direct English lexical evidence"
            ),
        },
        "outputs": {
            "direct": str(arguments.output.resolve()),
            "direct_sha256": sha256(arguments.output),
            "aliases": str(arguments.aliases_output.resolve()),
            "aliases_sha256": sha256(arguments.aliases_output),
        },
    }
    # The summary is the commit marker: write it only after both JSONL files have
    # been atomically replaced and their final hashes are known.
    atomic_write_text(
        arguments.summary,
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )

    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
