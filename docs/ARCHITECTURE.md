# Architecture

Goal: take the content of the Encarta 2003 Japanese DVD (Windows-only, dead front end)
and serve it from a native offline macOS app. The disc is a source, not a dependency.

## Pipeline

1. **Acquire** — mount the DVD/ISO read-only (`hdiutil attach -readonly -nobrowse`).
   Nothing is copied into the repo.
2. **Decode** — the payload is not files: it is 64 `.ITS` files, Microsoft InfoTech
   Storage (`ITSS`, same container family as `.CHM`) with LZX-compressed streams.
   Verified route: `7zz` opens them directly (`7zz l -slt` to enumerate members,
   `7zz x` to extract into a scratch dir), so no decoder has to be written — see
   `docs/DISC-SOURCES.md` for the layout and the measured timings.
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

The corpus is Japanese, and FTS5's default `unicode61` tokenizer cannot serve it.
Measured on the real extracted corpus (3,000 articles, SQLite 3.54):

- `unicode61` splits CJK only at punctuation, so a clause becomes one token. Those
  3,000 articles produced 150,099 distinct terms, **41.3 % of them longer than 12
  characters**, with a median term like `第39番札所の延光寺` — a whole clause, not a word.
- Consequence: a query matches only when it equals an entire punctuation-delimited run.
  Searching the exact article title `自由の女神` returns **0 hits**; `富士山` returns 6 only
  because some runs happen to be exactly that, while the 19 tokens that merely *begin*
  with it are unreachable.

`trigram` (SQLite ≥ 3.34, present here) fixes every query of three characters or more —
`自由の女神` → 1 hit, `富士山` → 21 on the same data — and it also survives mid-word
substring queries, which is what Japanese users actually type. It cannot serve
two-character queries at all: `火山` and `栄養` return 0 and must go to a `LIKE '%…%'`
scan over `articles`, or to a bigram index later if that scan proves too slow at full
corpus size.

So `index.py` should build the FTS table with `tokenize=trigram` for Japanese corpora,
route queries shorter than three characters to `LIKE`, and reserve `unicode61` for
Latin-script fixtures. Ranking stays bm25 with a title weight boost; snips come from
`snippet()`.

## What the Japanese data changes in the schema

- `word_count` counts whitespace-separated tokens and is meaningless here: measured
  averages were 11.6 "words" against 877 characters per article (longest 79,414
  characters). The corpus needs character counts; treat this as schema v2 rather than
  shipping a number the UI cannot explain.
- `slug` should be the disc's numeric `refid`: it is already ASCII and stable, so no
  transliteration is needed and cross-references resolve by id.
- `category`: articles carry no taxonomy on disc, so derive the browse axis from the
  metadata's `<jtitle>` (五十音 bucket) rather than inventing subject classes.

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
