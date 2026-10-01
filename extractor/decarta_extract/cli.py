"""Command line entry point: sample | ingest | query | verify | show | list."""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

from . import index
from .normalize import snip
from .sample import write_sample
from .sources import get_adapter


def _cmd_sample(args: argparse.Namespace) -> int:
    written = write_sample(Path(args.out))
    print(f"wrote {written} sample pages under {args.out}")
    return 0


def _resolve_tokenizer(requested: str, adapter_name: str) -> str:
    if requested != "auto":
        return requested
    # The sample fixture is Latin; the disc is Japanese and needs trigram.
    return "unicode61" if adapter_name == "generic-html" else "trigram"


def _cmd_ingest(args: argparse.Namespace) -> int:
    root = Path(args.root)
    if not root.is_dir():
        raise SystemExit(f"source tree not found: {root}")
    adapter = get_adapter(args.adapter)
    media_out = Path(args.media_out) if args.media_out else None
    if media_out is not None:
        media_out.mkdir(parents=True, exist_ok=True)

    tokenizer = _resolve_tokenizer(args.tokenizer, args.adapter)
    extra = {}
    if args.adapter == "encarta-its":
        extra["scratch"] = Path(args.scratch) if args.scratch else None
        extra["copy_media"] = media_out is not None

    articles = adapter(root, media_out=media_out, **{k: v for k, v in extra.items() if v is not None})
    if args.limit:
        articles = _take(articles, args.limit)
    counts = index.build(
        articles,
        Path(args.out),
        source_label=f"{args.adapter}:{root}",
        media_root=media_out,
        tokenizer=tokenizer,
    )
    print(
        f"corpus {args.out}: {counts['articles']} articles, "
        f"{counts['chars']} chars, {counts['media']} media refs, "
        f"{counts['xrefs']} cross-references (tokenizer {tokenizer})"
    )
    return 0


def _take(it, n: int):
    for i, item in enumerate(it):
        if i >= n:
            return
        yield item


def _cmd_query(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        rows = index.search(conn, args.text, limit=args.limit)
        if not rows:
            print("no matches")
            return 1
        for row in rows:
            reading = row["reading"]
            heading = f"{row['title']}" + (f"（{reading}）" if reading else "")
            print(f"{heading}  [{row['category']}]  ({row['char_count']} chars)")
            print(f"    {snip(row['snip'] or '', 28)}")
        return 0
    finally:
        conn.close()


def _cmd_show(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        row = conn.execute(
            "SELECT * FROM articles WHERE slug = ? OR title = ? COLLATE NOCASE"
            " OR reading = ? COLLATE NOCASE",
            (args.slug, args.slug, args.slug),
        ).fetchone()
        if row is None:
            print(f"no article {args.slug!r}", file=sys.stderr)
            return 1
        media = conn.execute(
            "SELECT kind, rel_path FROM media WHERE article_id = ?", (row["id"],)
        ).fetchall()
        xrefs = conn.execute(
            "SELECT target_slug, anchor FROM xrefs WHERE article_id = ? ORDER BY ordinal",
            (row["id"],),
        ).fetchall()
        header = f"{row['title']}"
        if row["reading"]:
            header += f"（{row['reading']}）"
        print(f"{header}\n{row['category']} · {row['char_count']} chars · {row['source_path']}\n")
        print(row["body"])
        for ref in media:
            print(f"\n[{ref['kind']}] {ref['rel_path']}")
        if xrefs:
            print("\nCross-references:")
            for ref in xrefs:
                print(f"  {ref['anchor']} -> {ref['target_slug']}")
        return 0
    finally:
        conn.close()


def _cmd_list(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        for row in index.categories(conn):
            print(f"{row['n']:5d}  {row['category']}")
        info = index.meta(conn)
        print(f"\nschema {info.get('schema_version')} · tokenizer {info.get('tokenizer')}"
              f" · source {info.get('source_label')} · built {info.get('built_at')}")
        return 0
    finally:
        conn.close()


def _cmd_verify(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        problems = index.check(conn)
        info = index.meta(conn)
        report = {
            "db": str(Path(args.db)),
            "schema_version": info.get("schema_version"),
            "tokenizer": info.get("tokenizer"),
            "articles": conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0],
            "categories": conn.execute("SELECT COUNT(DISTINCT category) FROM articles").fetchone()[0],
            "media": conn.execute("SELECT COUNT(*) FROM media").fetchone()[0],
            "xrefs": conn.execute("SELECT COUNT(*) FROM xrefs").fetchone()[0],
            "problems": problems,
        }
        # Round-trip real queries so the FTS path is exercised, not just counted:
        # a title term (the common case) and, for CJK corpora, a short one that must
        # take the LIKE fallback.
        report["fts_probes"] = probes = []
        for probe in _probes(conn, info.get("tokenizer", "unicode61")):
            report["fts_probes"].append(probe)
            if probe["hits"] == 0:
                problems.append(f"fts probe {probe['term']!r} returned no hits")
        print(json.dumps(report, indent=2, ensure_ascii=False))
        if problems:
            print("FAILED: " + "; ".join(problems), file=sys.stderr)
            return 1
        print("OK")
        return 0
    finally:
        conn.close()


def _probes(conn: sqlite3.Connection, tokenizer: str) -> list[dict]:
    probes: list[dict] = []
    row = conn.execute("SELECT title FROM articles ORDER BY id LIMIT 1").fetchone()
    if row:
        term = row["title"].split()[0] if " " in row["title"] else row["title"]
        probes.append({"term": term, "hits": len(index.search(conn, term, limit=5))})
    if tokenizer == "trigram":
        short = conn.execute("SELECT title FROM articles WHERE length(title) = 2 LIMIT 1").fetchone()
        if short:
            probes.append({"term": short["title"], "hits": len(index.search(conn, short["title"], limit=5))})
    return probes


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="decarta_extract", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("sample", help="generate the committed sample corpus")
    p.add_argument("-o", "--out", default="sample-data")
    p.set_defaults(func=_cmd_sample)

    p = sub.add_parser("ingest", help="parse a disc tree into a corpus.db")
    p.add_argument("root", help="mounted disc / ISO tree")
    p.add_argument("-o", "--out", default="build/corpus.db")
    p.add_argument("--adapter", default="generic-html",
                   help="generic-html (fixture/HTML discs) or encarta-its (the Encarta DVD)")
    p.add_argument("--media-out", default=None,
                   help="copy referenced assets here (default: don't copy)")
    p.add_argument("--tokenizer", default="auto", choices=["auto", *index.TOKENIZERS],
                   help="FTS tokenizer; auto picks per adapter (trigram for the disc)")
    p.add_argument("--scratch", default=None,
                   help="encarta-its: where to decode containers (default build/its-scratch)")
    p.add_argument("--limit", type=int, default=0, help="stop after N articles (debugging)")
    p.set_defaults(func=_cmd_ingest)

    p = sub.add_parser("query", help="full-text search a corpus")
    p.add_argument("text")
    p.add_argument("-d", "--db", default="build/corpus.db")
    p.add_argument("-n", "--limit", type=int, default=10)
    p.set_defaults(func=_cmd_query)

    p = sub.add_parser("show", help="print one article by slug or title")
    p.add_argument("slug")
    p.add_argument("-d", "--db", default="build/corpus.db")
    p.set_defaults(func=_cmd_show)

    p = sub.add_parser("list", help="categories and corpus metadata")
    p.add_argument("-d", "--db", default="build/corpus.db")
    p.set_defaults(func=_cmd_list)

    p = sub.add_parser("verify", help="integrity + FTS checks (exit 1 on failure)")
    p.add_argument("-d", "--db", default="build/corpus.db")
    p.set_defaults(func=_cmd_verify)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except sqlite3.OperationalError as exc:  # bad FTS query syntax, locked db, ...
        print(f"sqlite error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
