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


def _cmd_ingest(args: argparse.Namespace) -> int:
    root = Path(args.root)
    if not root.is_dir():
        raise SystemExit(f"source tree not found: {root}")
    adapter = get_adapter(args.adapter)
    media_out = Path(args.media_out) if args.media_out else None
    if media_out is not None:
        media_out.mkdir(parents=True, exist_ok=True)

    articles = adapter(root, media_out=media_out)
    if args.limit:
        articles = _take(articles, args.limit)
    counts = index.build(
        articles,
        Path(args.out),
        source_label=f"{args.adapter}:{root}",
        media_root=media_out,
    )
    print(
        f"corpus {args.out}: {counts['articles']} articles, "
        f"{counts['words']} words, {counts['media']} media refs"
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
            print(f"{row['title']}  [{row['category']}]  ({row['word_count']} words)")
            print(f"    {snip(row['snip'] or '', 28)}")
        return 0
    finally:
        conn.close()


def _cmd_show(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        row = conn.execute(
            "SELECT * FROM articles WHERE slug = ? OR title = ? COLLATE NOCASE",
            (args.slug, args.slug),
        ).fetchone()
        if row is None:
            print(f"no article {args.slug!r}", file=sys.stderr)
            return 1
        media = index_content = conn.execute(
            "SELECT kind, rel_path FROM media WHERE article_id = ?", (row["id"],)
        ).fetchall()
        print(f"{row['title']}\n{row['category']} · {row['word_count']} words · {row['source_path']}\n")
        print(row["body"])
        for ref in index_content:
            print(f"\n[{ref['kind']}] {ref['rel_path']}")
        return 0
    finally:
        conn.close()


def _cmd_list(args: argparse.Namespace) -> int:
    conn = index.connect_ro(Path(args.db))
    try:
        for row in index.categories(conn):
            print(f"{row['n']:5d}  {row['category']}")
        info = index.meta(conn)
        print(f"\nschema {info.get('schema_version')} · source {info.get('source_label')}"
              f" · built {info.get('built_at')}")
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
            "articles": conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0],
            "categories": conn.execute("SELECT COUNT(DISTINCT category) FROM articles").fetchone()[0],
            "media": conn.execute("SELECT COUNT(*) FROM media").fetchone()[0],
            "problems": problems,
        }
        # Round-trip one real query so the FTS path is exercised, not just counted.
        probe = conn.execute("SELECT title FROM articles LIMIT 1").fetchone()
        if probe:
            term = probe["title"].split()[0]
            hits = conn.execute(
                "SELECT COUNT(*) FROM articles_fts WHERE articles_fts MATCH ?", (term,)
            ).fetchone()[0]
            report["fts_probe"] = {"term": term, "hits": hits}
            if hits == 0:
                problems.append(f"fts probe {term!r} returned no hits")
        print(json.dumps(report, indent=2))
        if problems:
            print("FAILED: " + "; ".join(problems), file=sys.stderr)
            return 1
        print("OK")
        return 0
    finally:
        conn.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="decarta_extract", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("sample", help="generate the committed sample corpus")
    p.add_argument("-o", "--out", default="sample-data")
    p.set_defaults(func=_cmd_sample)

    p = sub.add_parser("ingest", help="parse a disc tree into a corpus.db")
    p.add_argument("root", help="mounted disc / ISO tree")
    p.add_argument("-o", "--out", default="build/corpus.db")
    p.add_argument("--adapter", default="generic-html")
    p.add_argument("--media-out", default=None,
                   help="copy referenced assets here (default: don't copy)")
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