# Decarta

Reuse the content of an outdated 2000s DVD encyclopedia (proprietary, offline, dead
front-end) inside a new native macOS launcher with a modern offline UI.

Two halves:

- `extractor/` — Python tooling that reads the encyclopedia off the disc and turns it
  into one portable, self-contained corpus: `corpus.db` (SQLite + FTS5 full-text index
  + media manifest). No network, ever.
- `app/` — a SwiftUI macOS app that opens `corpus.db` read-only and provides search,
  browse-by-category and article reading. The original disc is not required at runtime.

```
DVD / ISO  ──(extractor)──▶  corpus.db (+ media/)  ──(app)──▶  Decarta.app
                                  │
                        vendored, git-ignored
```

## Why a corpus file instead of reading the disc live

The disc's own viewer is what makes the content feel unusable — not the content. Baking
the data into a single indexed file means:

- the app has zero runtime dependency on a 20-year-old disc, mount point, or codec;
- the corpus is diffable-ish artifact you can validate, version and rebuild;
- the UI can be rewritten (SwiftUI today, anything tomorrow) without touching parsing.

## Layout

```
extractor/
  decarta_extract/
    cli.py          # ingest / query / verify / sample commands
    sources.py      # source adapters (generic-html adapter + hooks for disc-specific ones)
    normalize.py    # HTML → text, slugs, category assignment
    index.py        # SQLite + FTS5 writer, schema, verification
sample-data/        # tiny committed corpus so the repo works with no disc present
app/                # SwiftPM package, SwiftUI launcher
docs/               # architecture, corpus format, disc-source notes
```

## Quick start (no disc needed)

```sh
make sample      # write sample-data/ (already committed; regenerates it)
make ingest      # sample-data/ -> build/corpus.db
make verify      # integrity, counts, FTS round-trip
make query Q="volcano"
make app         # swift build
make run         # launch the GUI against build/corpus.db
```

Once you have the real media mounted, point the ingester at the disc tree:

```sh
python3 -m decarta_extract ingest /Volumes/ENCYCLOPEDIA_2003 --adapter generic-html \
    -o build/corpus.db --media-out build/media
```

## Legal / provenance

`vendor/`, `media/`, `build/` and any raw disc content are git-ignored: the disc's data
is copyrighted and stays on the user's machine. The repo holds only tooling, a small
hand-written sample corpus, and the app. Do not commit extracted encyclopedia content
or a built `corpus.db`.

## Status

Extractor, corpus format and app shell work end to end against the sample corpus.
The disc-specific adapter (the real parser for whatever the 2000s media actually ships
— HTML tree, custom binary index, embedded viewer database) is still to be written;
`docs/DISC-SOURCES.md` tracks what it needs to handle.