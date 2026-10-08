# Dictionary data and licensing

The application source and dictionary data are separate works. The repository's MIT License covers the project's source code and documentation; it does not grant rights to third-party dictionary text, exam material, datasets, APIs, or user-supplied databases.

## Why the full database is not in Git

The historical `words.db` was assembled across multiple development stages. Although the current database records provenance and clearly marks generated IELTS-style examples, not every legacy row has documentation sufficient to prove public redistribution rights. Publishing the complete file under an open-source repository license would therefore overstate the available rights.

The local file remains usable by its owner and is ignored by Git. Contributors must not add it, or a derivative export of it, to a pull request unless every included source is documented and redistribution-compatible.

## Supported locations

The application checks these locations in order:

1. `IELTS-Vocab.app/Contents/Resources/words.db`
2. `~/.ielts-vocab/words.db`

`build.sh` embeds `Resources/words.db` only when the file exists. A fresh public checkout works without it and falls back to local cache, macOS DictionaryServices, and optional network providers.

## Schema

The canonical schema is tracked in [`Resources/words.schema.sql`](../Resources/words.schema.sql). JSON fields use the following shapes:

```json
{
  "definitions": [{"pos": "noun", "meaning": "中文释义", "example": "Original example."}],
  "phrases": [{"text": "a collocation", "meaning": "中文释义", "type": "collocation"}],
  "ielts_examples": [{"sentence": "Original IELTS-style sentence.", "source": "AI-generated IELTS-style example", "year": ""}]
}
```

Valid phrase types are `formal`, `slang`, `idiom`, `phrasalVerb`, and `collocation`.

## Authenticity rules

- Model-generated examples must use the source label `AI-generated IELTS-style example`.
- Generated text must never be represented as a real IELTS, Cambridge, British Council, or IDP exam question.
- Authentic exam text requires explicit redistribution permission plus a verifiable citation.
- Legacy rows without verified provenance must remain labeled `legacy_unverified`.
- A legal inflection alias may reuse a lemma only when it does not erase an independent or ambiguous sense.

## Adding a dataset

A data contribution should include:

1. dataset name, exact version, original URL, and acquisition date;
2. license/SPDX identifier and the required attribution text;
3. whether modified data may be redistributed and under what terms;
4. a deterministic import script rather than an unexplained database dump;
5. integrity checks, row counts, schema checks, and representative tests;
6. provenance for every generated or merged row.

If the licensing answer is unclear, do not commit the data. Keep it local and provide an adapter or import script instead.

## Optional build pipeline

The guarded pipeline is:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r BatchBuilder/requirements-expansion.txt

python BatchBuilder/generate_expansion_candidates.py
DEEPSEEK_API_KEY='…' python BatchBuilder/expand_words.py
python Analysis/create_words_db_quality_notebook.py
```

The pipeline requires an existing locally authorized database and may use optional third-party datasets. Running it does not by itself make the output redistributable; review every input license before publishing an output database.
