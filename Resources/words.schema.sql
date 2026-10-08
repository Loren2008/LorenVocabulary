PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS words (
    word TEXT PRIMARY KEY,
    phonetic TEXT,
    definitions TEXT,
    phrases TEXT,
    ielts_examples TEXT,
    examples TEXT,
    source TEXT
);

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
    FOREIGN KEY (word) REFERENCES words(word) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS word_aliases (
    alias TEXT PRIMARY KEY,
    lemma TEXT NOT NULL,
    display_word TEXT NOT NULL,
    form_type TEXT NOT NULL,
    provenance TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    FOREIGN KEY (lemma) REFERENCES words(word) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_word_aliases_lemma ON word_aliases(lemma);
