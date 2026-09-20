# Architecture

Goal: take the content of the Encarta 2003 Japanese DVD (Windows-only, dead front end)
and serve it from a native offline macOS app. The disc is a source, not a dependency.

## Pipeline

1. **Acquire** — mount the DVD/ISO read-only (`hdiutil attach -readonly -nobrowse`).
   Nothing is copied into the repo.
2. **Decode** — the payload is not files: it is 64 `.ITS` files, Microsoft InfoTech
   Storage (`ITSS`, same container family as `.CHM`) with LZX-compressed streams. Read
   the ITSS directory, then inflate the streams into an inner tree in a scratch dir (or
   stream them in memory). This stage is source-agnostic plumbing; see
   `docs/DISC-SOURCES.md` for the exact byte layout on this disc.
3. **Parse** — the `encarta-its` adapter walks that inner tree and yields normalized
   `Article` records (`slug`, `title`, `body`, `category`, `source_path`, media refs).
   Article text, media and catalog indexes come from separate containers
   (`CONT*` / `CATALOG.STE` vs. `MED*` / `PICON*` / `THUMB*` / `SW*`).
4. **Normalize** — decoded text (CP932 or UTF-16LE on the Japanese disc; HTML/legacy
   rich text where applicable) is flattened to plain text with paragraph breaks; slugs
   are derived from titles and de-duplicated. Japanese titles need a slug strategy that
   survives non-ASCII (transliteration or stable ids — not a naive ASCII squeeze).
5. **Index** — records are written into `corpus.db`: an `articles` table, a `media`
   table keyed by article, and FTS5 virtual tables over title/body.
6. **Ship/open** — the macOS app opens `corpus.db` read-only (`SQLITE_OPEN_READONLY`,
   `file:...?mode=ro` URI) and never writes to it.

`generic-html` (step 3's other adapter) stays in the tree as a fixture/self-test path
and for any HTML-shaped disc; it does not fit this disc.

## Corpus schema (v1)

```sql
articles(id INTEGER PK, slug TEXT UNIQUE, title TEXT NOT NULL, body TEXT,
         category TEXT, source_path TEXT, word_count INTEGER)
media(id INTEGER PK, article_id INTEGER REFERENCES articles(id),
      kind TEXT, rel_path TEXT, caption TEXT)
meta(key TEXT PK, value TEXT)          -- schema_version, source_label, built_at
articles_fts                           -- fts5(title, body, content='articles',
                                       --      content_rowid='id', tokenize ...)
```

`meta.schema_version` gates compatibility: the app refuses a corpus it does not know
rather than half-rendering it.

## Search, and why Japanese changes it

The corpus is Japanese, and FTS5's default `unicode61` tokenizer is unusable for it.
Measured on SQLite 3.54: the sentence

    富士山は日本で最も高い山である。火山としても知られる。

tokenizes as **two tokens**, `富士山は日本で最も高い山である` and `火山としても知られる`
— unicode61 treats runs of CJK as single alphanumeric tokens and finds no word
boundaries. A query for `富士山`, or even for the exact sentence token, returns nothing
useful for search UX.

The `trigram` tokenizer (SQLite ≥ 3.34, present here) fixes all queries of three
characters or more: `富士山`, `である`, and any longer substring match. It cannot serve
two-character queries at all — `火山` and `富士` return zero hits and must be routed to a
`LIKE '%…%'` scan over the article table (or a bigram index later if that scan is too
slow at full corpus size).

So `index.py` should build the FTS table with `tokenize=trigram` for Japanese corpora,
keep a `LIKE` fallback for <3-character queries, and reserve `unicode61` for
Latin-script fixtures. Ranking is bm25 with a title weight boost; snips come from
`snippet()`.

## App

- SwiftPM executable target, SwiftUI `App` lifecycle, macOS 13+.
- Reads the corpus path from `--corpus <path>` (default `build/corpus.db`, then
  `~/Library/Application Support/Decarta/corpus.db`).
- `--selftest <corpus.db>` runs the same query path headlessly and exits non-zero on
  failure, so the parser→index→reader chain is testable without a GUI.
- Read-only access only: the app cannot corrupt a corpus it is browsing.
- Japanese input and display are the target case, not an afterthought: IME text entry,
  CJK line-breaking (no space-delimited words), vertical-ish typography not required,
  but full-width/half-width and kana/kanji matching are.

## Non-goals

- No network calls, no auto-update, no telemetry.
- Not a general EPUB/PDF reader: the UI is shaped around an A–Z encyclopedia corpus.
- No redistribution of disc content: extraction is local, output is git-ignored, and
  the app ships no content.
