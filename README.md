# decarta

Reuse an outdated 2000s Windows encyclopedia — Microsoft Encarta 2003, Japanese
edition (disc `L03JXLRD`) — inside a new native macOS app. Port the content, not the
viewer: the original disc is a Windows-only, IE-embedded front end reading proprietary
compressed containers, and that front end is exactly what makes a perfectly good
reference work unusable today.

What we want out of the disc is the text and the media. Everything else on it is 2002
Windows plumbing to be thrown away.

Two halves:

- `extractor/` — Python tooling that reads the encyclopedia off the ISO/DVD and bakes it
  into one portable, self-contained corpus: `corpus.db` (SQLite + FTS5 full-text index
  + media manifest). No network, ever.
- `app/` — a SwiftUI macOS app that opens `corpus.db` read-only and provides search,
  browse-by-category and article reading. The disc is not needed at runtime.

```
Encarta 2003 DVD  ──(extractor)──▶  corpus.db (+ media/)  ──(app)──▶  decarta.app
      │                                   │
  mounted read-only                  vendored, git-ignored
```

## The source disc

`encarta2003.iso` (repo root, git-ignored) is a private image of an authentic Encarta
2003 DVD, Japanese SKU (`L03JXLRD`, *Microsoft エンカルタ 総合大百科 2003*). One disc,
752 files, 2.2 GB. The encyclopedia payload is 64 `.ITS` files (~1.4 GB): Microsoft
InfoTech Storage (`ITSS`) containers whose streams are LZX-compressed — the same
container family `.CHM` uses. Nothing on the disc is readable as-is, and the only
`.htm` files present are the shell's own UI pages.

`docs/DISC-SOURCES.md` holds the byte-level survey of what is actually on the disc;
`docs/ARCHITECTURE.md` describes the pipeline that turns it into a corpus. This is a
Japanese corpus, so the reader and the search index both have to handle Japanese text
properly — see the search notes in the architecture doc.

## Legal / provenance

Personal-use tooling for content the user already owns on disc. The repo contains no
encyclopedia content and can't reproduce any: the ISO, the extracted corpus and the
media tree are all git-ignored, extraction happens locally, and the app never fetches
anything. Nothing here redistributes or republishes the encyclopedia — it builds a
reader for a copy you already have. The only content committed to the repo is a small
hand-written fixture under `sample-data/`, written for this project.

Do not commit the ISO, extracted content, or a built `corpus.db`.

## Layout

```
extractor/
  decarta_extract/
    cli.py          # sample / ingest / query / show / list / verify commands
    sources.py      # adapter registry + generic-html (fixture/HTML discs)
    encarta.py      # encarta-its: the Encarta 2003 disc adapter (ITSS + 7-Zip)
    normalize.py    # text flattening, slugs, character counts, 五十音 buckets
    index.py        # SQLite + FTS5 writer (schema v2), tokenizer-aware search
sample-data/        # tiny hand-written corpus, a pipeline fixture (not the product)
app/                # SwiftPM package, SwiftUI reader
scripts/
  build-app.sh      # ingest the disc, build the reader, package a self-contained .app
packaging/
  Info.plist        # bundle template; version and build number filled in at package time
docs/               # architecture, corpus format, disc-source notes
```

## The packaged app

`make dist` (or `scripts/build-app.sh`) ingests the disc, builds the reader in release
configuration, and assembles a bundle that carries its own content:

```
build/decarta.app/Contents/
  MacOS/decarta              # the reader
  Info.plist                 # version from `git describe`, bundle id com.nelforzo.decarta
  Resources/corpus.db        # the whole corpus (SQLite + FTS5)
  Resources/media/baggage/   # the pictures the corpus references
  Resources/decarta.icns     # the icon (regenerate with packaging/make-icon.py)
```

The corpus is written into the bundle with `VACUUM INTO` and left in rollback-journal
mode rather than WAL. A WAL-mode database makes the reader create `-shm`/`-wal` sidecars
beside it on first open, which would litter `Resources/` and break the code signature of
a bundle that is meant to be read-only.

The bundle is self-contained and location-independent: the corpus records an absolute
`media_root` from the machine that built it, so the reader prefers that path only if it
still exists and otherwise falls back to `media/` beside `corpus.db`. It is ad-hoc signed
(`codesign --sign -`), which is enough to launch locally and to keep the app's identity
when it is moved, without pretending to be a notarised distribution.

The icon is a 5x7 pixel-font `d` on a white rounded square, drawn as literal squares so
the letter stays hard-edged; only the rounded background is supersampled. `make-icon.py`
regenerates `decarta.icns` if the design changes — it is not needed for a normal build.

```sh
SKIP_INGEST=1 ./scripts/build-app.sh   # repackage from an existing corpus.db in seconds
cp -R build/decarta.app /Applications/
```

## Quick start

```sh
make                 # sample corpus -> verify -> app build -> headless selftest

# The real disc (see below for the mount):
make mount           # hdiutil attach -readonly -nobrowse -mountpoint /tmp/encarta_mnt
make ingest-disc     # DISC defaults to /tmp/encarta_mnt; copies pictures (MEDIA=0 to skip)
make verify
make list            # 五十音 bucket counts
make query Q="自由の女神"
make run

# A self-contained app you can keep in /Applications:
make dist            # ingest the disc, build, and package build/decarta.app
```

Without a disc, the same commands work against `sample-data/`:

```sh
make ingest SOURCES=sample-data ADAPTER=generic-html   # writes build/corpus.db
```

## Status

- **The disc ingests end to end.** `make ingest-disc` builds a complete corpus from
  `encarta2003.iso`: **39,491 articles, 30,007,400 characters, 55,265 media references,
  306,408 article-to-article cross-references**, `verify` clean. Measured 62 s cold
  (one-time 7-Zip decode of `DATASTD`/`CONTSTD`, ~6 s) and 56 s with the containers
  already decoded in `build/its-scratch`. `corpus.db` is 349 MB.
- Corpus schema is **v2**: character counts instead of whitespace `word_count`, the kana
  reading, article cross-references, and a per-corpus FTS tokenizer. Search is
  `trigram` for the disc (substring matching, what Japanese users type) with a `LIKE`
  fallback for two-character queries; `unicode61` is kept for the Latin fixture.
- Browse axis is a 五十音 bucket derived from the disc's own kana reading
  (`<jtitle>`); 38,893 of 39,491 articles land in a かな row, 21 in その他.
- The app reads the corpus read-only and adds cross-reference navigation, "referenced
  by" backlinks, media with captions, paged entry lists and 五十音 sidebar sections.
- Pictures: `make ingest-disc MEDIA=1` copies every referenced picture — **8,157 files
  (.jpg/.gif), 215 MiB** — into `build/media/baggage/`, and the reader displays them with
  captions. The manifest comes from the catalog's `<assoc group="media">` links, so only
  pictures an article actually references are copied; the three containers that hold them
  are unpacked once each and pruned. Proprietary thumbnail derivatives (`.jsm`/`.jtn`/`.
  gsm`/`.gtn`) and audio/video stay referenced-but-uncopied — the documented long tail.
  `media.caption` holds the asset's title; the disc's longer descriptive `<caption>` text
  (2.0M characters) is parsed but not yet stored — see `docs/DISC-SOURCES.md`.
