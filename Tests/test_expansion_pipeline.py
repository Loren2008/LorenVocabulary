import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "BatchBuilder"))
import expand_words  # noqa: E402


class ExpansionPipelineTests(unittest.TestCase):
    def candidate(self):
        return {
            "word": "chopper",
            "display_word": "chopper",
            "category": "rare_word",
            "lemma": "chopper",
            "provenance": ["test"],
        }

    def response(self, phrase="chopper bike", phrase_type="technical"):
        return {
            "phonetic": "/ˈtʃɒpə/",
            "definitions": [
                {"pos": "n.", "meaning": "砍刀；直升机", "example": "A chopper landed nearby."}
            ],
            "phrases": [
                {"text": phrase, "meaning": "定制摩托车", "type": phrase_type}
            ],
            "ielts_style_sentence": "The chopper was used during the rescue operation.",
        }

    def stored_payload(self, candidate=None):
        candidate = candidate or self.candidate()
        response = self.response(phrase=f"{candidate['word']} example")
        return expand_words.validate_entry(response, candidate)

    def test_normalizes_typographic_word_forms(self):
        self.assertEqual(expand_words.normalize_word("  CAN’T  "), "can't")
        self.assertEqual(expand_words.normalize_word("off‑putting"), "off-putting")
        self.assertEqual(expand_words.fold_for_match("Åland"), "aland")

    def test_accepts_headword_collocation_and_normalizes_unknown_type(self):
        payload = expand_words.validate_entry(self.response(), self.candidate())
        self.assertEqual(payload["phrases"][0]["type"], "collocation")
        self.assertEqual(
            payload["ielts_examples"][0]["source"],
            "AI-generated IELTS-style example",
        )

    def test_rejects_semantically_drifting_phrase_without_headword(self):
        with self.assertRaisesRegex(ValueError, "does not contain"):
            expand_words.validate_entry(self.response(phrase="pork chop"), self.candidate())

    def test_explicit_model_rejection_is_terminal_not_retried(self):
        response = {
            "results": [
                {
                    "word": "chopper",
                    "accepted": False,
                    "reason": "identity cannot be established",
                }
            ]
        }
        with mock.patch.object(expand_words, "api_request", return_value=(response, {})):
            outcome = expand_words.process_batch(
                [self.candidate()], "secret", "https://api.deepseek.com/chat/completions", "test"
            )
        self.assertIn("chopper", outcome.rejected)
        self.assertNotIn("chopper", outcome.retry)

    def test_headword_matching_allows_compound_and_possessive_equivalents(self):
        self.assertTrue(expand_words.phrase_contains_headword("lenzs-law", "Lenz's law"))
        self.assertTrue(
            expand_words.phrase_contains_headword("speed-of-light", "speed of light")
        )
        self.assertTrue(expand_words.phrase_contains_headword("Cristi", "Cristi's work"))
        self.assertFalse(expand_words.phrase_contains_headword("he", "the hero"))
        self.assertFalse(expand_words.phrase_contains_headword("chopper", "pork chop"))

    def test_strict_app_json_rejects_top_object_and_numeric_member(self):
        self.assertIsNone(
            expand_words.strict_json_object_list(
                '{"sentence":"x","source":"y"}', ("sentence", "source")
            )
        )
        self.assertIsNone(
            expand_words.strict_json_object_list(
                '[{"sentence":"x","source":"y","year":2024}]',
                ("sentence", "source"),
            )
        )

    def test_partial_selection_requires_explicit_nonpublish_or_override(self):
        arguments = SimpleNamespace(
            limit=1,
            categories="",
            words="",
            no_publish=False,
            publish_partial=False,
        )
        with self.assertRaisesRegex(SystemExit, "Partial selection"):
            expand_words.validate_publish_scope(arguments)
        arguments.no_publish = True
        expand_words.validate_publish_scope(arguments)

    def test_endpoint_is_official_https_and_redirects_are_disabled(self):
        self.assertEqual(
            expand_words.endpoint_from_base("https://api.deepseek.com/v1"),
            "https://api.deepseek.com/v1/chat/completions",
        )
        for endpoint in (
            "http://api.deepseek.com",
            "https://api.deepseek.com.evil.test",
            "https://user@api.deepseek.com",
        ):
            with self.assertRaises(SystemExit):
                expand_words.endpoint_from_base(endpoint)
        handler = expand_words.NoAuthorizationRedirectHandler()
        self.assertIsNone(handler.redirect_request(None, None, 302, "redirect", {}, "https://evil"))

    def test_manifest_summary_binds_database_and_both_jsonl_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "words.db"
            direct = root / "direct.jsonl"
            aliases = root / "aliases.jsonl"
            summary = root / "summary.json"
            database.write_bytes(b"source")
            direct.write_text('{"word":"one"}\n', encoding="utf-8")
            aliases.write_text(
                '{"word":"ones","lemma":"one"}\n', encoding="utf-8"
            )
            summary.write_text(
                json.dumps(
                    {
                        "database_sha256": expand_words.sha256_file(database),
                        "direct_candidates": 1,
                        "inflection_aliases": 1,
                        "outputs": {
                            "direct_sha256": expand_words.sha256_file(direct),
                            "aliases_sha256": expand_words.sha256_file(aliases),
                        },
                    }
                ),
                encoding="utf-8",
            )
            expand_words.validate_manifest_summary(
                summary, database, direct, aliases
            )
            database.write_bytes(b"changed")
            with self.assertRaisesRegex(SystemExit, "database_sha256"):
                expand_words.validate_manifest_summary(
                    summary, database, direct, aliases
                )

    def test_repair_fields_are_inferred_or_explicit_without_whole_row_rewrite(self):
        candidate = {**self.candidate(), "category": "repair"}
        fields = expand_words.repair_fields_for_row(
            candidate,
            (
                '[{"pos":"n.","meaning":"释义","example":"Example."}]',
                '[{"text":"chopper bike","meaning":"搭配","type":"collocation"}]',
                '[{"sentence":"Sentence.","source":"legacy","year":2024}]',
            ),
        )
        self.assertEqual(fields, {"ielts_examples"})
        candidate["repair_fields"] = ["phrases"]
        self.assertEqual(
            expand_words.repair_fields_for_row(candidate, ("bad", "bad", "bad")),
            {"phrases"},
        )

    def test_repair_authenticity_tracks_whether_ielts_was_replaced(self):
        candidate = {**self.candidate(), "category": "repair"}
        self.assertEqual(
            expand_words.content_authenticity_for_candidate(candidate, {"phrases"}),
            "legacy_unverified",
        )
        self.assertEqual(
            expand_words.content_authenticity_for_candidate(
                candidate, {"phrases", "ielts_examples"}
            ),
            "generated_style",
        )
        self.assertEqual(
            expand_words.content_authenticity_for_candidate(self.candidate(), None),
            "generated_style",
        )

    def test_reuse_state_ignores_repair_fields_but_not_proper_subtype(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_path = root / "old.sqlite3"
            target_path = root / "target.sqlite3"
            old = sqlite3.connect(old_path)
            old.execute(
                "CREATE TABLE jobs(word TEXT PRIMARY KEY,candidate_json TEXT,status TEXT,payload_json TEXT)"
            )
            repair = {**self.candidate(), "category": "repair"}
            proper = {
                **self.candidate(),
                "word": "aaron",
                "display_word": "Aaron",
                "lemma": "aaron",
                "category": "proper_noun",
            }
            old.executemany(
                "INSERT INTO jobs VALUES (?,?,?,?)",
                [
                    (
                        repair["word"],
                        json.dumps(repair),
                        "success",
                        json.dumps(self.stored_payload(repair)),
                    ),
                    (
                        proper["word"],
                        json.dumps(proper),
                        "success",
                        json.dumps(self.stored_payload(proper)),
                    ),
                ],
            )
            old.commit()
            old.close()
            target = sqlite3.connect(target_path)
            target.execute(
                "CREATE TABLE jobs(word TEXT PRIMARY KEY,candidate_json TEXT,status TEXT,payload_json TEXT,last_error TEXT,updated_at TEXT)"
            )
            target.execute(
                "CREATE TABLE run_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)"
            )
            repair_new = {
                **repair,
                "repair_fields": ["ielts_examples"],
                "provenance": ["new audit wording"],
            }
            proper_new = {**proper, "subtype": "person"}
            for item in (repair_new, proper_new):
                target.execute(
                    "INSERT INTO jobs VALUES (?,?, 'pending',NULL,NULL,'now')",
                    (item["word"], json.dumps(item)),
                )
            imported = expand_words.import_compatible_successes(
                target, old_path, [repair_new, proper_new]
            )
            self.assertEqual(imported, 1)
            statuses = dict(target.execute("SELECT word,status FROM jobs"))
            self.assertEqual(statuses["chopper"], "success")
            self.assertEqual(statuses["aaron"], "pending")
            reused_payload = json.loads(
                target.execute(
                    "SELECT payload_json FROM jobs WHERE word='chopper'"
                ).fetchone()[0]
            )
            self.assertEqual(reused_payload["provenance"], ["new audit wording"])
            target.close()

    def test_run_metadata_prevents_cross_source_state_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "run.sqlite3"
            candidate = self.candidate()
            state = expand_words.initialize_state(
                state_path, [candidate], False, {"source_database_sha256": "one"}
            )
            state.close()
            with self.assertRaisesRegex(SystemExit, "metadata does not match"):
                expand_words.initialize_state(
                    state_path,
                    [candidate],
                    False,
                    {"source_database_sha256": "two"},
                )

    def test_attempts_increment_only_for_submitted_work(self):
        connection = sqlite3.connect(":memory:")
        connection.execute(
            "CREATE TABLE jobs(word TEXT PRIMARY KEY,candidate_json TEXT,status TEXT,attempts INTEGER,payload_json TEXT,last_error TEXT,prompt_tokens INTEGER,completion_tokens INTEGER,updated_at TEXT)"
        )
        candidates = []
        for index in range(5):
            candidate = {
                "word": f"word{index}",
                "display_word": f"word{index}",
                "category": "rare_word",
                "lemma": f"word{index}",
                "provenance": ["test"],
            }
            candidates.append(candidate)
            connection.execute(
                "INSERT INTO jobs VALUES (?,?, 'pending',0,NULL,NULL,0,0,'now')",
                (candidate["word"], json.dumps(candidate)),
            )
        arguments = SimpleNamespace(max_attempts=4, batch_size=1, workers=1, model="test")
        with mock.patch.object(
            expand_words, "process_batch", side_effect=expand_words.FatalAPIError("stop")
        ):
            with self.assertRaises(expand_words.FatalAPIError):
                expand_words.run_generation(
                    connection, arguments, "secret", "https://api.deepseek.com/chat/completions"
                )
        attempts = [row[0] for row in connection.execute("SELECT attempts FROM jobs ORDER BY word")]
        self.assertEqual(attempts, [1, 0, 0, 0, 0])
        connection.close()

    def test_publishability_allows_only_nonrepair_quarantine(self):
        connection = sqlite3.connect(":memory:")
        connection.execute(
            "CREATE TABLE jobs(word TEXT,candidate_json TEXT,status TEXT)"
        )
        connection.executemany(
            "INSERT INTO jobs VALUES (?,?,?)",
            [
                ("good", json.dumps({"category": "rare_word"}), "success"),
                ("bad", json.dumps({"category": "rare_word"}), "quarantined"),
                ("repair", json.dumps({"category": "repair"}), "success"),
            ],
        )
        gate = expand_words.publishability(connection)
        self.assertEqual(gate["pending"], 0)
        self.assertEqual(gate["repair_not_success"], 0)
        self.assertEqual(gate["excluded_nonrepair"], 1)
        connection.execute("UPDATE jobs SET status='quarantined' WHERE word='repair'")
        self.assertEqual(expand_words.publishability(connection)["repair_not_success"], 1)
        connection.close()

    def test_publish_field_merges_repair_and_rebuilds_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "words.db"
            backup_dir = root / "backups"
            candidate_file = root / "candidates.jsonl"
            alias_file = root / "aliases.jsonl"
            original_definitions = (
                '[ {"pos":"noun","meaning":"legacy meaning",'
                '"example":"Legacy example.","note":"keep me"} ]'
            )
            original_phrases = (
                '[{"text":"chopper bike","meaning":"旧搭配","type":"collocation"}]'
            )
            connection = sqlite3.connect(database)
            connection.execute(
                "CREATE TABLE words(word TEXT PRIMARY KEY,phonetic TEXT,definitions TEXT,"
                "source TEXT,examples TEXT,phrases TEXT,ielts_examples TEXT)"
            )
            connection.executemany(
                "INSERT INTO words VALUES (?,?,?,?,?,?,?)",
                [
                    (
                        "chopper",
                        "/old/",
                        original_definitions,
                        "legacy-source",
                        '["Legacy example."]',
                        original_phrases,
                        '[{"sentence":"Old.","source":"legacy","year":2020}]',
                    ),
                    (
                        "walk",
                        "",
                        '[{"pos":"v.","meaning":"走","example":"We walk."}]',
                        "legacy-source",
                        '["We walk."]',
                        '[{"text":"walk home","meaning":"走回家","type":"collocation"}]',
                        '[{"sentence":"People walk.","source":"legacy","year":"2020"}]',
                    ),
                ],
            )
            connection.commit()
            connection.close()

            candidate = {
                **self.candidate(),
                "category": "repair",
                "repair_fields": ["ielts_examples"],
            }
            aliases = [
                {
                    "word": "walks",
                    "lemma": "walk",
                    "display_word": "walks",
                    "form_type": "third_person_singular",
                    "provenance": ["test"],
                }
            ]
            candidate_file.write_text(json.dumps(candidate) + "\n", encoding="utf-8")
            alias_file.write_text(json.dumps(aliases[0]) + "\n", encoding="utf-8")
            state = sqlite3.connect(":memory:")
            state.execute(
                "CREATE TABLE jobs(word TEXT,status TEXT,payload_json TEXT)"
            )
            payload = self.stored_payload(candidate)
            state.execute(
                "INSERT INTO jobs VALUES (?, 'success', ?)",
                (candidate["word"], json.dumps(payload)),
            )
            arguments = SimpleNamespace(
                db=database,
                backup_dir=backup_dir,
                model="test-model",
                candidates=candidate_file,
                aliases=alias_file,
            )
            source_hash = expand_words.sha256_file(database)
            backup, quality = expand_words.publish_database(
                state,
                [candidate],
                aliases,
                arguments,
                "test-run",
                {"success": 1},
                source_hash,
            )
            self.assertTrue(backup.is_file())
            self.assertEqual(quality["aliases_written"], 1)
            published = sqlite3.connect(database)
            row = published.execute(
                "SELECT definitions,phrases,ielts_examples,source FROM words WHERE word='chopper'"
            ).fetchone()
            self.assertEqual(row[0], original_definitions)
            self.assertEqual(row[1], original_phrases)
            self.assertEqual(row[2], json.dumps(payload["ielts_examples"], ensure_ascii=False, separators=(",", ":")))
            self.assertEqual(row[3], "legacy-source")
            self.assertEqual(
                published.execute("SELECT alias,lemma FROM word_aliases").fetchone(),
                ("walks", "walk"),
            )
            published.execute(
                "INSERT INTO word_aliases VALUES (?,?,?,?,?,?)",
                ("chopper", "walk", "chopper", "test", "[]", "now"),
            )
            published.commit()
            with self.assertRaisesRegex(RuntimeError, "collides"):
                expand_words.validate_database(published, 2)
            published.close()
            state.close()

    def test_sqlite_backup_is_logically_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.db"
            backup = Path(directory) / "backup.db"
            connection = sqlite3.connect(source)
            connection.execute(
                """
                CREATE TABLE words(
                    word TEXT PRIMARY KEY, phonetic TEXT, definitions TEXT,
                    source TEXT, examples TEXT, phrases TEXT, ielts_examples TEXT
                )
                """
            )
            connection.execute(
                "INSERT INTO words VALUES (?,?,?,?,?,?,?)",
                ("test", "", "[]", "test", "[]", "[]", "[]"),
            )
            connection.commit()
            connection.close()
            expand_words.sqlite_backup(source, backup)
            self.assertEqual(
                expand_words.logical_words_hash(source),
                expand_words.logical_words_hash(backup),
            )

    def test_cas_guard_refuses_sqlite_sidecars(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "words.db"
            database.write_bytes(b"db")
            Path(f"{database}-wal").write_bytes(b"active")
            with self.assertRaisesRegex(RuntimeError, "sidecars"):
                expand_words.ensure_no_sqlite_sidecars(database)


if __name__ == "__main__":
    unittest.main()
