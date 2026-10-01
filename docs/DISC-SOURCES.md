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

The payload is 64 `.ITS` files (~1.4 GB). Roles below are now verified, not inferred:

| Path | Role |
| --- | --- |
| `EE/ENCARTA/DATASTD.ITS` (12 MB) | master catalog: 72,696 `data/<refid>.xml` metadata records |
| `CONTENT/CONTSTD.ITS` (38 MB) | article bodies: 40,323 `content/<refid>.xml` |
| `CONTENT/CONTDLX.ITS` (3,162 files), `CONTEWA.ITS` | partial text from the other SKUs |
| `CONTENT/MED*`, `PICON*`, `THUMB*`, `SW*` (`.ITS`) | `baggage/<member>` media bytes |
| `EE/ENCARTA/DATADLX.ITS` (11,608 records), `DATAEWA/EDA/ESA` | metadata for the other SKUs |
| `EE/ENCARTA/CATALOG.STE` | `catalog2/baggage.ecs` = baggage member index |
| `EE/ENCARTA/ENCXSL.ITS` | 68 XSLT stylesheets (`art.xsl`, …) — the original renderer's rules |
| `EE/ENCARTA/FIND*.ITS`, `IDXJSTE.ITS`, `WLNK*.ITS` | the viewer's proprietary full-text/word indexes — ignore, we build our own |
| `PFILES/MSREF/BS3J/1041/BS02J.ITS` | 277,495 `.htm` members: a second, HTML-shaped reference work (JP MS Reference) |
| `CONTENT/FLIGHTS/*.FLY` | custom binary (flight simulator data) — ignore |
| `AREF/`, `REDIST/`, `SYSTEM/`, `EE/ENCARTA/*.EXE|.DLL` | 2002 Windows runtime — ignore |

Container framing (probed by hand):

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
  bytes anywhere in the large `.ITS` files. Members are unreadable until inflated.

## Content model (verified)

No binary format has to be reverse-engineered. Once the containers are opened, the
whole encyclopedia is XML keyed by a numeric `refid`, and the joins are explicit:

- **Catalog** — `DATASTD.ITS` holds one record per object, `data/<refid>.xml`, tagged
  `<data refid="…" group="…">`. Groups: 39,491 `article`, 17,992 `media`, 9,036
  `weblink`, 3,111 `timeevent`, 1,608 `audio`, 1,001 `expert`, 829 `sidebar`, 516
  `table`, 383 `audionested`, 877+121 virtual tours, plus popup/composite/interact/
  director/timetopic/quickstart/map… Article records carry `<title>` and `<jtitle>`
  (the kana rendering — useful for a 五十音 sort index).
- **Bodies** — `content/<refid>.xml`: `<content refid><text>` with 188,161 `<pkey>`
  paragraphs, 54,475 `<section>`/`<sectiontitle>` pairs and 307,363 `<xref>` elements
  (types 8 = main cross-reference, plus 14/15/11/10). Inline markup: `<b>`, `<i>`,
  `<sup>`, `<sub>`, `<fs>`, `<headline>`, `<list>`/`<listitem>`, `<inlinebmp>`,
  `<quote>`, `<author>`. UTF-8 already — no CP932/UTF-16 archaeology needed.
- **Join** — every one of the 39,491 article refids has a body: 0 missing. The 832
  extra bodies are sidebar/table-class text blobs.
- **Media** — records point at `msencdata::baggage/<member>`; those bytes are members
  named `baggage/<member>` inside the MED/PICON/THUMB/SW containers, indexed by
  `CATALOG.STE`'s `catalog2/baggage.ecs`. Audit over all 66 containers: 75,892
  references, 75,738 present on this disc, 154 missing — every missing one a Macromedia
  Director `.dcr`. So this single disc is effectively self-contained.
- **Links** — 117,207 `<assoc refid="…" group="article">` elements (in `reverse`/
  `forward` blocks) tie media, timelines, tables and tours to their articles, so the
  media manifest needs no heuristics.
- **Fidelity reference** — `ENCXSL.ITS` ships the viewer's own XSLT, including
  `art.xsl`, so rendering decisions can follow the original rather than be invented.

## Feasibility probe (throwaway, outside the repo)

- Decompression needs no code: 7-Zip 26.03 opens `.ITS` directly (`Type = Hxs`).
  `CONTSTD.ITS` (38 MB) extracts to 40,323 files / 206 MB in 3.4 s.
- A throwaway adapter (title metadata joined to bodies, fed through the existing
  `index.build`) produced all 40,320 articles into a 208 MB `corpus.db` in 19.8 s;
  `decarta_extract verify` reported `problems: []` and a clean FTS probe. The corpus
  schema and app fit this data unchanged.
- Measured frictions: `unicode61` cannot search Japanese properly (see ARCHITECTURE);
  `word_count` is meaningless for Japanese (~11.6 "words" vs 877 chars average);
  `.jsm`/`.jtn`/`.gsm`/`.gtn` thumbnails are proprietary formats; Deluxe-only items
  referencing other discs are absent by design.

## Adapter contract

```python
def iter_articles(root: Path, *, media_out: Path | None = None) -> Iterator[Article]
```

An adapter must be pure and deterministic: same disc, same corpus. It must not write
into the source tree (media is copied out to `--media-out`, never modified in place).
Mounts are read-only, and nothing extracted is committed.

## `encarta-its` — implemented, and what it cost

The adapter lives in `extractor/decarta_extract/encarta.py` and is wired into the CLI as
`--adapter encarta-its` (`make ingest-disc`). What it does, in the order it runs:

1. **Open the containers.** Shells out to `7zz` (LGPL, present on this machine, opens
   `.ITS` directly as `Hxs`). `7zz l -slt` enumerates members; `7zz x` decodes into a
   scratch tree (`build/its-scratch/<container>`, reused across runs so the 1.4 GB of
   containers is decoded once, not per ingest). A pure-Python ITSS+LZX reader remains
   optional and unwritten — the external dependency is 7-Zip and nothing else.
2. **Catalog pass.** `EE/ENCARTA/DATASTD.ITS` → `data/<refid>.xml` (72,696 records);
   keeps `group="article"`, reads `<title>` and `<jtitle>`, and records the
   `<forward>`/`<reverse>` `<assoc>` links and the `<files>` asset references.
3. **Body pass.** `CONTENT/CONTSTD.ITS` → `content/<refid>.xml` (40,323 members), parsed
   with `xml.etree`: `<pkey>`/`<sectiontitle>`/`<headline>`/`<listitem>` become
   paragraphs, `<xref>` becomes inline text plus a recorded `RefID`, inline `b/i/sup/sub`
   survive as text, and `<sec>`/`<inlinebmp>` are dropped.
4. **Media pass.** The manifest comes from the article record's `<assoc group="media">`
   links, resolved through the media records' `<files>` children, which name members as
   `msencdata::baggage/<member>` — and the media containers store exactly `baggage/<member>`.
   **Pictures** (`<image>` → `.jpg`/`.gif`) are copied to `--media-out` by extracting the
   three containers that hold them (`MEDSTD00`, `MEDSTD01`, `MEDSTD`) once each and
   pruning to the referenced members — 8,157 files / 215 MiB / 2.9 s, versus one 7-Zip
   call per member. ``<ticon>`` is skipped: it is the same generic type icon on every
   record, not article content. `<picon>`/`<thumb>` are recorded as `thumbnail`
   (proprietary `.jsm`/`.jtn`/`.gsm`/`.gtn`) and, with audio/video, stay
   referenced-but-uncopied. `meta.media_root` is written absolute so the reader can
   resolve the files from any working directory.
5. **Text handling.** Bodies are UTF-8, so no CP932 path is needed here; `_decode`'s
   never-raise behaviour is retained for other containers. The slug is the numeric
   `refid`. The reading comes from `<jtitle>` with the leading repeat of the display title
   stripped (`自由の女神像　じゆうのめがみぞう　Statue of Liberty` → `じゆうのめがみぞう
   Statue of Liberty`), and the browse category is the 五十音 row of the first kana in it.

Measured on the full disc (`make ingest-disc`, containers already decoded):

```
39491 articles · 30007400 chars · 55265 media refs · 306408 xrefs
tokenizer trigram · corpus.db 349 MB · verify: problems []
selftest (app, headless): OK
```

Bucket distribution: あ行 5973, か行 7309, さ行 6326, た行 4766, な行 2315, は行 6359,
ま行 2569, や行 1131, ら行 1871, わ行 274, A–Z 536, 0–9 41, その他 21.

Two corrections to the notes above, found while implementing:

- **`CONTEWA.ITS` is not openable by 7-Zip** (`Cannot open the file as archive`). Since
  every Standard-catalog article refid already has a body in `CONTSTD.ITS`, the adapter
  treats the other-SKU containers as optional and skips one it cannot read rather than
  failing the ingest.
- **`<title>`, `<jtitle>` and `<caption>` are not plain strings.** They carry inline
  markup (`<fs>`, `<tbd>`, `<it>`, `<sup>`, `<inf>`, `<break>`), so reading the element's
  `.text` yields either nothing (when the tag comes first) or a prefix truncated at the
  first nested tag. Measured on the real catalog: 718 `<title>` elements have empty
  direct text and 27 more are partially truncated; 120 `<jtitle>` (7 empty, 113
  truncated); 203 `<caption>` (4 empty, 199 truncated). Symptoms: six articles whose
  title fell back to their numeric refid (`1161537290` instead of `氐`), and image
  captions cut mid-title. Parse these fields with a recursive inline-text walk. —
  `verify` now flags `title = slug` so this cannot ship silently again.
- The adapter reports 55,265 media refs, which is a different measure from the survey's
  75,892 above: the survey counted every `<files>` child across all record groups
  (including each record's generic `<ticon>` type icon), while the adapter counts only
  content assets (`<image>`, `<thumb>`, `<picon>`) reached from an article's
  `<assoc group="media">` links. Excluding the `<ticon>` icons alone accounted for ~19.8k
  of the difference.

Still open (unchanged, and out of scope here): conversion of proprietary thumbnails,
`.dcr` (dead), audio/video, and rendering fidelity from `ENCXSL.ITS`.

Also open, found while fixing the title parsing: **the disc's media `<caption>` text is
parsed but discarded.** 15,874 of 17,992 media records carry one — 2,046,514 characters
of description — while `media.caption` currently holds the record's *title* (the adapter
uses `title or caption` precedence). Storing both needs a schema addition plus a reader
change to show the description under the image.


## Generic shapes (context for the adapter interface)

| Shape | Symptoms on disc | Adapter | Status |
| --- | --- | --- | --- |
| ITSS container store | `*.ITS` files, `ITOLITLS`/`ITSF` magic, LZX streams | `encarta-its` | **implemented and verified on the Encarta 2003 disc** |
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
