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

## `encarta-its` — design, now that the format is known

1. **Open the containers.** Verified route: shell out to `7zz` (LGPL, already present on
   this machine, opens `.ITS` directly as `Hxs`). `list_tsv = 7zz l -slt` for the member
   inventory; `7zz x -o<scratch>` for extraction — either into a scratch dir the adapter
   reads, or streamed member by member with `-so`. A pure-Python ITSS+LZX reader
   (`itss.py`) is optional, ~600–900 lines, and only worth it if we want zero external
   dependencies.
2. **Catalog pass.** `EE/ENCARTA/DATASTD.ITS` → `data/<refid>.xml`; keep
   `group="article"` records, read `<title>` and `<jtitle>`.
3. **Body pass.** `CONTENT/CONTSTD.ITS` → `content/<refid>.xml`; flatten `<pkey>`
   paragraphs to text, keep `<section>`/`<sectiontitle>` structure and `<xref>`
   targets. Then merge other-SKU containers (`CONTDLX`, `CONTEWA`) for anything the
   Standard catalog references and the Standard container lacks.
4. **Media pass.** Build one member index over MED/PICON/THUMB/SW containers plus
   `CATALOG.STE`, resolve `msencdata::baggage/<member>`, copy to `--media-out`, and
   attach to articles via the `<assoc group="article">` links in the metadata records.
   Convert what we can (`.jpg`/`.gif`/`.wav`/`.wma`); leave proprietary thumbnails
   (`.jsm`/`.jtn`/`.gsm`/`.gtn`) referenced but unconverted in v1.
5. **Text handling.** Bodies are already UTF-8, so `sources._decode` needs no CP932
   path for this disc — but keep the never-raise behaviour for other containers.
   Japanese titles/`jtitle` drive a stable slug: use the numeric `refid` (already
   ASCII), so no transliteration is needed.
6. **Schema/UI follow-ups this data forces.** Character counts instead of
   whitespace `word_count`; the trigram + `LIKE` search path (below); a category
   derived from `jtitle` (五十音 bucket) since articles carry no taxonomy of their own.

## Generic shapes (context for the adapter interface)

| Shape | Symptoms on disc | Adapter | Status |
| --- | --- | --- | --- |
| ITSS container store | `*.ITS` files, `ITOLITLS`/`ITSF` magic, LZX streams | `encarta-its` | **target of this project**; format verified, adapter to write |
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
