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
3. **Parse** — the `encarta-its` adapter (`extractor/decarta_extract/encarta.py`) walks
   that inner tree with 7-Zip and yields normalized `Article` records (`slug`, `title`,
   `reading`, `body`, `category`, `source_path`, media refs, cross-references). Article
   text, media and catalog indexes come from separate containers (`CONT*` / `CATALOG.STE`
   vs. `MED*` / `PICON*` / `THUMB*` / `SW*`). The join is the numeric `refid`
   (`docs/DISC-SOURCES.md`).
4. **Normalize** — bodies are UTF-8 XML: `<pkey>` paragraphs and `<sectiontitle>` heads
   are flattened to paragraph-separated text, `<xref>` becomes inline text plus a
   recorded link target, and inline `b/i/sup/sub/fs` survive as text. The slug is the
   disc's numeric `refid` (already ASCII and stable), the reading comes from `<jtitle>`,
   and the browse category is a 五十音 bucket derived from that reading.
5. **Index** — records are written into `corpus.db`: an `articles` table, `media` keyed by
   article, `xrefs` for cross-references, and an FTS5 table over title/reading/body.
6. **Ship/open** — the macOS app opens `corpus.db` read-only (`SQLITE_OPEN_READONLY`,
   `file:...?mode=ro` URI) and never writes to it.

`generic-html` (step 3's other adapter) stays in the tree as a fixture/self-test path
and for any HTML-shaped disc; it does not fit this disc.

## Corpus schema (v2)

```sql
articles(id INTEGER PK, slug TEXT UNIQUE, title TEXT NOT NULL, reading TEXT,
         body TEXT NOT NULL, category TEXT NOT NULL, source_path TEXT,
         char_count INTEGER NOT NULL)
media(id INTEGER PK, article_id → articles(id), kind TEXT, rel_path TEXT, caption TEXT)
xrefs(id INTEGER PK, article_id → articles(id), target_slug TEXT, anchor TEXT,
      ordinal INTEGER)
meta(key TEXT PK, value TEXT)          -- schema_version, tokenizer, source_label,
                                       -- built_at, *_count, media_root
articles_fts                           -- fts5(title, reading, body, content='articles',
                                       --      content_rowid='id', tokenize=<trigram|unicode61>)
```

`meta.schema_version` gates compatibility: the app refuses a corpus it does not know
rather than half-rendering it. `meta.tokenizer` tells both the CLI and the app how to
search this corpus, so the tokenizer choice travels with the data.

v1 (`word_count`, `unicode61` only) is gone: see below.

## Search, and why Japanese changes it

The corpus is Japanese, and FTS5's default `unicode61` tokenizer cannot serve it.
Measured on the real extracted corpus (3,000 articles, SQLite 3.54):

- `unicode61` splits CJK only at punctuation, so a clause becomes one token. Those
  3,000 articles produced 150,099 distinct terms, **41.3 % of them longer than 12
  characters**, with a median term like `第39番札所の延光寺` — a whole clause, not a word.
- Consequence: a query matches only when it equals an entire punctuation-delimited run.
  Searching the exact article title `自由の女神` returned **0 hits**; `富士山` returned 6 only
  because some runs happened to be exactly that, while the 19 tokens that merely *begin*
  with it were unreachable.

`trigram` (SQLite ≥ 3.34) fixes every query of three characters or more and also survives
mid-word substring queries, which is what Japanese users actually type. It cannot serve
two-character queries at all.

So `index.py` builds the FTS table with `tokenize=trigram` for the disc and
`tokenize=unicode61 remove_diacritics 2` for the Latin fixture (`--tokenizer auto` picks
by adapter; the value is stored in `meta.tokenizer`). `index.search` dispatches on it:

- **Terms.** The query is split on whitespace and every term must match (AND). It is
  tried exactly as typed first and only re-tried NFKC-normalized if that finds nothing.
  Measured: a multi-word query matches 28 articles where the old whole-query-as-one-phrase
  form matched 0 (`自由 女神`), and normalizing *only* on the second attempt is what keeps
  a title with full-width punctuation findable (`JAL（ジャル）`) while still resolving IME
  artefacts (`ＦＵＪＩ` 0 → 5 hits, half-width `ﾌｼﾞ` 0 → 126).
- **trigram, all terms ≥ 3 characters** → FTS5 `MATCH` of each term as a quoted phrase
  joined with `AND` (a substring match, which is how CJK is searched), ranked by bm25.
  Sub-millisecond; even a 7,302-hit term ranks in 22 ms.
- **trigram, any term < 3 characters** → the `LIKE` path. `火山` matches 797 articles and
  `日本` 11,334, so ranking all of them by `length(title)` cost **82-104 ms**. Instead
  titles/readings are queried and ranked on their own — few rows, and the most relevant
  ones anyway — and the body only fills the rest of the page unordered: **30-75 ms for a
  page of 300**, where the old shape spent ~100 ms on a page of 60.
- **`unicode61` corpus** → per-token `MATCH`, quoting each token so prose punctuation
  cannot become FTS syntax, with a prefix on the last token so search feels live while
  typing (there is no trigram substring path to make that unnecessary).

Ranking is bm25 with a title boost (8.0 title, 4.0 reading, 1.0 body); snippets come from
`snippet()`, and the `LIKE` path falls back to the first 160 characters of the body.

**Counting.** `index.search` and the reader report the real total where it is cheap: a
`COUNT` over the FTS index is effectively free, so `セックス` reports 104 instead of the
page size it used to be silently clamped to (60, labelled as if it were the total). The
`LIKE` path cannot count without an ~80-90 ms scan, so it says "N+" rather than invent a
number.

**Cross-language normalization.** `unicode61`-style normalization is *not* portable:
Swift's `precomposedStringWithCompatibilityMapping` decomposes half-width kana to a
full-width base plus a combining mark (U+30D5 U+30B7 U+3099 for `ﾌｼﾞ`) and does not compose
it back, while Python's `NFKC` yields U+30D5 U+30B8 (what the corpus stores). The Swift
reader applies a canonical-composition pass on top, and `--selftest` asserts that a
half-width query returns exactly the same hits as its full-width form (126 = 126).

`verify` round-trips a title term *and*, for trigram corpora, a real two-character query,
so both paths are exercised rather than just counted.

## What the Japanese data changed in the schema

These are applied in v2, not proposals:

- `word_count` counted whitespace-separated tokens and is meaningless here: measured
  averages were 11.6 "words" against 877 characters per article (longest 79,414
  characters). v2 stores `char_count` (characters excluding whitespace) — 30,007,400
  characters over 39,491 articles on the real disc.
- `slug` is the disc's numeric `refid`: already ASCII and stable, so no transliteration
  is needed and cross-references resolve by id.
- `category` is a 五十音 bucket derived from the metadata's `<jtitle>` reading
  (articles carry no taxonomy of their own): 38,893 of 39,491 land in a かな row.
- `xrefs` makes the 306,408 article-to-article cross-references navigable instead of
  leaving them as dead inline text.

## Pictures

The reader shows the disc's pictures; nothing else from `<files>` is converted yet.

- Every `<image>` member an article references is copied to `--media-out`
  (`build/media/baggage/<name>`), and the corpus records `meta.media_root` so the app can
  find them. On this disc that is **8,157 files (6,921 `.jpg`, 1,236 `.gif`), 215 MiB**,
  referenced 15,673 times by 39,491 articles — so most pictures are shared between
  articles and deduplication matters.
- Copying is done container-by-container: the pre-pass collects the needed members, the
  three containers that hold them (`MEDSTD00`, `MEDSTD01`, `MEDSTD`) are extracted once
  each, then pruned to just the referenced members. Whole-container extraction beats
  per-member extraction because 7-Zip must inflate the containing block regardless —
  measured 2.9 s for all 8,157, against ~8,000 subprocess invocations the naive way.
  Containers already fully copied are skipped on re-ingest.
- `meta.media_root` is stored **absolute**; the app also accepts a relative value and
  anchors it to the corpus's own directory, so a corpus behaves the same wherever it is
  opened from.
- `<thumb>`/`<picon>` (`.jsm`/`.jtn`/`.gsm`/`.gtn`) and audio/video stay
  referenced-but-uncopied; the reader labels them as such rather than showing a gap.
- `--selftest` asserts that sampled picture rows resolve to files, since the media path
  is otherwise invisible to a headless run.

## App

- SwiftPM executable target, SwiftUI `App` lifecycle, macOS 13+.
- Reads the corpus path from `--corpus <path>` (default `build/corpus.db`, then
  `~/Library/Application Support/Decarta/corpus.db`).
- `--selftest <corpus.db>` runs the same query path headlessly and exits non-zero on
  failure, so the parser→index→reader chain is testable without a GUI.
- Read-only access only: the app cannot corrupt a corpus it is browsing.
- Three-pane `NavigationSplitView`: 五十音 bucket sidebar → entry list → reader.
  - The entry list is paged (`pageSize` 250, next page appended as you scroll). Handing
    all 39,491 rows to a `List` at once stalls the first frame and makes AppKit log a
    reentrancy warning.
  - Selection handlers and `loadNextPage` run on the next main-loop turn rather than
    inside AppKit's own selection callback.
  - The reader shows the kana reading, character count and source path, renders the body
    as spaced paragraphs, shows copied media images with captions, and turns the `xrefs`
    into clickable "See also" links plus a "Referenced by" list (from `backlinks`).
  - A back button (`⌘[`) walks the reading history, so following cross-references is
    reversible.
- Search mirrors the corpus's tokenizer (see above), so a two-character Japanese query
  works in the GUI exactly as it does in the CLI.
- Japanese display is the target case, not an afterthought: no space-delimited words to
  reflow, so paragraphs are separated by spacing; full-width/half-width and kana/kanji
  matching matter, and the reading field makes titles sortable.
- `make dist` / `scripts/build-app.sh` packages a self-contained `Decarta.app`: the
  release binary, `Resources/corpus.db`, `Resources/media/` and `Resources/Decarta.icns`,
  ad-hoc signed. Inside a `.app` the bundle's own corpus wins over `build/corpus.db` in
  the working directory, and a recorded absolute `media_root` is only honoured while it
  exists — otherwise the reader falls back to `media/` beside the corpus, so the app keeps
  working after being moved.
- The bundled corpus is written with `VACUUM INTO` and left in rollback-journal mode, not
  WAL: a WAL database makes the reader create `-shm`/`-wal` beside it on first open, which
  would modify the app bundle and break its signature. The build inspects the bundle only
  before signing, for the same reason, and fails if reading the corpus creates sidecars.
- The icon is generated by `packaging/make-icon.py` (a 5x7 pixel-font `d` drawn as literal
  squares on a white rounded square) and committed as `packaging/Decarta.icns`, so a normal
  build needs no image tooling.

## Non-goals

- No network calls, no auto-update, no telemetry.
- Not a general EPUB/PDF reader: the UI is shaped around an A–Z encyclopedia corpus.
- No redistribution of disc content: extraction is local, output is git-ignored, and
  the app ships no content.
