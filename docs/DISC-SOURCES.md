# Disc source notes

The ingester is adapter-based because 2000s encyclopedia discs differ wildly. Known
shapes to expect and how the tooling handles each:

| Shape | Symptoms on disc | Adapter | Status |
| --- | --- | --- | --- |
| HTML tree + images | `*.htm`/`*.html` with a frameset index, `images/` next to them | `generic-html` | implemented |
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

## Adapter contract

```python
def iter_articles(root: Path, *, media_out: Path | None = None) -> Iterator[Article]
```

An adapter must be pure and deterministic: same disc, same corpus. It must not write
into the source tree (media is copied out to `--media-out`, never modified in place).

## When the real disc arrives

1. `ls`/`du` the mount point, note top-level structure and the largest file types.
2. Run `generic-html` first — it covers most DHTML-era discs outright.
3. For a viewer-DB disc, dump the header bytes of the biggest `.dat`/`.idx` and check
   for a record-length table (fixed-stride records are the common case, which is
   trivial to carve); add an adapter rather than special-casing the CLI.
4. Record findings here and keep one regression fixture per disc in `sample-data/`
   (hand-written, tiny, copyright-safe).