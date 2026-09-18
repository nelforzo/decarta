# Architecture

## Pipeline

1. **Acquire** — mount the DVD / ISO image read-only. Nothing is copied into the repo.
2. **Parse** — a source adapter walks the disc tree and yields normalized `Article`
   records (`slug`, `title`, `body`, `category`, `source_path`, media refs).
3. **Normalize** — HTML (and legacy rich-text where applicable) is flattened to plain
   text with paragraph breaks; slugs are derived from titles and de-duplicated.
4. **Index** — records are written into `corpus.db`: an `articles` table, a `media`
   table keyed by article, and an FTS5 virtual table over title/body.
5. **Ship/open** — the macOS app opens `corpus.db` read-only (`SQLITE_OPEN_READONLY`,
   `file:...?mode=ro` URI) and never writes to it.

## Corpus schema (v1)

```sql
articles(id INTEGER PK, slug TEXT UNIQUE, title TEXT NOT NULL, body TEXT,
         category TEXT, source_path TEXT, word_count INTEGER)
media(id INTEGER PK, article_id INTEGER REFERENCES articles(id),
      kind TEXT, rel_path TEXT, caption TEXT)
meta(key TEXT PK, value TEXT)          -- schema_version, source_label, built_at
articles_fts                           -- fts5(title, body, content='articles',
                                       --      content_rowid='id', tokenize unicode61)
```

`meta.schema_version` gates compatibility: the app refuses a corpus it does not know
rather than half-rendering it.

Search uses FTS5 `unicode61` with `remove_diacritics` on, so accented filenames and
article titles match without the user typing accents. Ranking is bm25 with a title
weight boost; snips come from `snippet()`.

## App

- SwiftPM executable target, SwiftUI `App` lifecycle, macOS 13+.
- Reads the corpus path from `--corpus <path>` (default `build/corpus.db`, then
  `~/Library/Application Support/Decarta/corpus.db`).
- `--selftest <corpus.db>` runs the same query path headlessly and exits non-zero on
  failure, so the parser→index→reader chain is testable without a GUI.
- Read-only access only: the app cannot corrupt a corpus it is browsing.

## Non-goals

- No network calls, no auto-update, no telemetry.
- Not a general EPUB/PDF reader: the UI is shaped around an A–Z encyclopedia corpus.