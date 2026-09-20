# Decarta

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
Encarta 2003 DVD  ──(extractor)──▶  corpus.db (+ media/)  ──(app)──▶  Decarta.app
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
    cli.py          # ingest / query / verify / sample commands
    sources.py      # source adapters (generic-html today; encarta-its is the target)
    normalize.py    # HTML → text, slugs, category assignment
    index.py        # SQLite + FTS5 writer, schema, verification
sample-data/        # tiny hand-written corpus, a pipeline fixture (not the product)
app/                # SwiftPM package, SwiftUI launcher
docs/               # architecture, corpus format, disc-source notes
```

## Quick start

```sh
hdiutil attach -readonly -nobrowse encarta2003.iso     # mount the disc read-only

make sample      # write the sample-data/ fixture (already committed)
make ingest      # fixture -> build/corpus.db (SOURCES defaults to sample-data)
make verify      # integrity, counts, FTS round-trip
make query Q="volcano"
make app         # swift build
make run         # launch the GUI against build/corpus.db
```

Ingesting the real disc is the same command with the mount point and the disc's adapter:

```sh
python3 -m decarta_extract ingest /Volumes/L03JXLRD1 --adapter encarta-its \
    -o build/corpus.db --media-out build/media
```

## Status

- Extractor, corpus format and app shell work end to end — but only against the
  `sample-data/` fixture. That fixture exercises the pipeline; it is not the product.
- The disc itself is not ingestible yet. The `generic-html` adapter finds 35 UI-chrome
  pages and zero articles on this disc; the real content sits inside LZX-compressed
  `ITSS` streams and needs an `encarta-its` adapter (ITSS directory reader + LZX
  decoder). That adapter is the critical path and is not written yet.
- After the adapter: Japanese search indexing (see architecture doc), then media
  (images/audio/video) into the manifest.
