# Disc source notes

The project targets one disc: **Encarta 2003, Japanese SKU `L03JXLRD`**
(`encarta2003.iso`, a private image of an authentic Encarta 2003 DVD). Everything in
this file exists to get that disc's content out; the generic shapes below are context
for the adapter interface and for the sample fixture.

## Target: `encarta2003.iso` — Microsoft Encarta 2003, Japanese, disc `L03JXLRD`

Mounted read-only with
`hdiutil attach -readonly -nobrowse -mountpoint /tmp/encarta_mnt encarta2003.iso`
(volume name `L03JXLRD1`). One disc, 752 files, 2.2 GB.

**There is no HTML tree to ingest.** Only 38 files are `.htm`/`.html`, and every one is
shell or UI chrome: `ELC/LESSONS/*`, `ELC/MENU.HTM`, `CONTENT/FLIGHTS/*.HTM`,
`SUPPORT/DIRHTML/`. Ingesting the mount with `generic-html` yields 35 "articles" /
2560 words / 0 media refs across categories `Dirhtml`, `Elc`, `Flights`, `Lessons`:
zero encyclopedia text. That corpus is UI residue, not content — do not ship it or
treat its counts as meaningful.

The payload is 64 `.ITS` files (~1.4 GB):

| Path | Role (inferred) |
| --- | --- |
| `CONTENT/CONTSTD.ITS` (38 MB) | article text, Standard edition |
| `CONTENT/CONTDLX.ITS`, `CONTEWA.ITS` | article text variants (Deluxe / other SKU) |
| `CONTENT/MED*`, `PICON*`, `THUMB*`, `SW*` (`.ITS`) | media, pictures, thumbnails, sounds |
| `EE/ENCARTA/CATALOG.STE` | catalog index, lists members in the clear |
| `EE/ENCARTA/*.ITS` | viewer data, localization tables |
| `CONTENT/FLIGHTS/*.FLY` | custom binary (flight simulator data) — ignore |
| `AREF/`, `REDIST/`, `SYSTEM/`, `EE/ENCARTA/*.EXE|.DLL` | 2002 Windows runtime — ignore |

What the bytes say (probed by hand, not yet by an adapter):

- Magic is `ITOLITLS`, and each file carries an `ITSF` v4 header (32-byte header,
  langid field `0x409`) — the Microsoft InfoTech Storage (`ITSS`) container family, the
  same one `.CHM` uses.
- Exactly one `LZXC` control block per file, and the storage tree names
  `::DataSpace/Storage/MSCompressed/{Content,ControlData,SpanInfo,ResetTable}` with
  transform `{0A9007C6-4076-11D3-8789-0000F8105754}`: every stream is LZX-compressed
  with a reset table. `CATALOG.STE` names its members in plaintext —
  `/catalog2/content.ecn`, `/catalog2/data.ecn`, `/catalog2/guid.lst`, … — so the
  catalog's structure is discoverable before any decompression works.
- Nothing is stored uncompressed: no HTML tags, and no Shift-JIS run longer than ~20
  bytes anywhere in the large `.ITS` files. Text is unreadable until the LZX streams
  are inflated.
- The edition is Japanese, so expect CP932 or UTF-16LE text after inflation, and
  full-width punctuation in titles (`、`/`。`) that normalization must handle.

## Adapter contract

```python
def iter_articles(root: Path, *, media_out: Path | None = None) -> Iterator[Article]
```

An adapter must be pure and deterministic: same disc, same corpus. It must not write
into the source tree (media is copied out to `--media-out`, never modified in place).
Mounts are read-only, and nothing extracted is committed.

## `encarta-its` (the adapter this disc needs) — to write

1. **ITSS reader**: parse the `ITSF` header and directory (or `::DataSpace/NameList`) to
   enumerate streams inside each `.ITS`.
2. **LZX decoder**: inflate `MSCompressed` streams honouring `ResetTable` chunking.
   This is the real work; the container framing around it is small.
3. **Inner-tree pass**: classify what falls out — `CONT*`/`CATALOG.STE` → articles,
   `MED*`/`PICON*`/`THUMB*`/`SW*` → media, `.FLY` → skip. Titles and the article
   ordering are likely driven by `CATALOG.STE`'s `/catalog2/guid.lst`.
4. **Text decode**: add `cp932` and `utf-16` to `sources._decode` before trusting the
   Japanese text; keep the existing never-raise behaviour.

Cheapest first probe: check whether an off-the-shelf ITSS/LZX reader (7-Zip opens
`ITSF` containers) can list and extract one `.ITS` before writing an LZX decoder by
hand. If yes, the adapter can shell out for the decode step; if no, a pure-Python LZX
inflater is required and should live in `extractor/decarta_extract/itss.py`.

## Generic shapes (context for the adapter interface)

| Shape | Symptoms on disc | Adapter | Status |
| --- | --- | --- | --- |
| ITSS container store | `*.ITS` files, `ITOLITLS`/`ITSF` magic, LZX streams | `encarta-its` | **target of this project**, blocked on ITSS+LZX reader |
| HTML tree + images | `*.htm`/`*.html` with a frameset index, `images/` next to them | `generic-html` | implemented (fixture path) |
| Static HTML + proprietary viewer DB | `.dat`/`.idx`/`.mdb` beside a bundled viewer app | needs reverse engineering | not started |
| Rich text / Word docs | `.rtf`, `.doc` per entry | `rtf` | planned (extractor can read via macOS `textutil`) |
| Video/audio clips | `.mov`, `.avi`, `.wav` referenced by entries | media manifest only (no transcode in v1) | planned |

## What `generic-html` assumes

- Any file with `.htm`/`.html`/`.xhtml` extension is a candidate article.
- Title comes from `<h1>`, then `<title>`, then the first `<font size=6>`-ish heading
  (common in this era), then the filename.
- Body is all text outside `<script>`/`<style>`/`<head>`, whitespace-collapsed.
- Category is the name of the closest ancestor directory that is not `images/`,
  `text/`, `data/` or a numbered shard.
- Files under `images/`, `_derived/`, `help/` are skipped as non-articles.

## Adding a disc shape

1. `ls`/`du` the mount point, note top-level structure and the largest file types.
2. Dump header bytes of the biggest unknown file and check for a container magic or a
   record-length table (fixed-stride records are the common case, which is trivial to
   carve); add an adapter rather than special-casing the CLI.
3. Point the ingester at it:
   `python3 -m decarta_extract ingest <mount> --adapter <name> -o build/corpus.db --media-out build/media`.
4. Record findings here, and keep one hand-written, copyright-safe regression fixture
   per shape in `sample-data/`.
