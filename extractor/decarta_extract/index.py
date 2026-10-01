"""Corpus builder: SQLite + FTS5 index over normalized articles.

Schema v2 exists because the corpus is Japanese. v1 shipped a whitespace `word_count`
(meaningless for CJK) and a `unicode61` FTS table (which cannot serve Japanese — see
`docs/ARCHITECTURE.md`). v2 stores character counts, the kana reading used for the
browse axis and for search, article cross-references, and picks its tokenizer per corpus:

* `trigram` for CJK — matches substrings of three or more characters, which is what
  Japanese users type; shorter queries fall back to a `LIKE` scan.
* `unicode61` for Latin-script corpora (the `sample-data` fixture).
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from .sources import Article

SCHEMA_VERSION = "2"

# Tokenizers we can build an FTS table with. `jc` marks the CJK path (trigram + LIKE).
TOKENIZERS = {"trigram": True, "unicode61": False}
MIN_TRIGRAM_CHARS = 3

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE articles (
    id          INTEGER PRIMARY KEY,
    slug        TEXT NOT NULL UNIQUE,
    title       TEXT NOT NULL,
    reading     TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL,
    category    TEXT NOT NULL,
    source_path TEXT NOT NULL,
    char_count  INTEGER NOT NULL
);

CREATE TABLE media (
    id         INTEGER PRIMARY KEY,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    rel_path   TEXT NOT NULL,
    caption    TEXT NOT NULL DEFAULT ''
);

CREATE TABLE xrefs (
    id          INTEGER PRIMARY KEY,
    article_id  INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    target_slug TEXT NOT NULL,
    anchor      TEXT NOT NULL,
    ordinal     INTEGER NOT NULL
);

CREATE INDEX idx_articles_category ON articles(category);
CREATE INDEX idx_articles_title ON articles(title);
CREATE INDEX idx_media_article ON media(article_id);
CREATE INDEX idx_xrefs_article ON xrefs(article_id);
CREATE INDEX idx_xrefs_target ON xrefs(target_slug);

CREATE VIRTUAL TABLE articles_fts USING fts5(
    title,
    reading,
    body,
    content='articles',
    content_rowid='id',
    tokenize="__TOKENIZER__"
);

CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, reading, body)
    VALUES (new.id, new.title, new.reading, new.body);
END;

CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, reading, body)
    VALUES ('delete', old.id, old.title, old.reading, old.body);
END;

CREATE TRIGGER articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, reading, body)
    VALUES ('delete', old.id, old.title, old.reading, old.body);
    INSERT INTO articles_fts(rowid, title, reading, body)
    VALUES (new.id, new.title, new.reading, new.body);
END;
"""


def _fts_ddl(tokenizer: str) -> str:
    if tokenizer not in TOKENIZERS:
        raise ValueError(f"unknown tokenizer {tokenizer!r}; known: {', '.join(TOKENIZERS)}")
    if tokenizer == "unicode61":
        clause = "unicode61 remove_diacritics 2"
    else:
        clause = tokenizer
    return SCHEMA.replace("__TOKENIZER__", clause)


def build(articles: Iterable[Article], db_path: Path, *, source_label: str,
          media_root: Path | None = None, replace: bool = True,
          tokenizer: str = "trigram") -> dict[str, int]:
    """Write a corpus. Returns counts; caller decides what to log."""
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if replace and db_path.exists():
        for suffix in ("", "-wal", "-shm"):
            sidecar = db_path.with_name(db_path.name + suffix)
            sidecar.unlink(missing_ok=True)

    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(_fts_ddl(tokenizer))
        n_articles = n_media = n_xrefs = total_chars = 0
        for article in articles:
            cur = conn.execute(
                "INSERT INTO articles"
                " (slug, title, reading, body, category, source_path, char_count)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (article.slug, article.title, article.reading, article.body,
                 article.category, article.source_path, article.chars),
            )
            article_id = int(cur.lastrowid or 0)
            n_articles += 1
            total_chars += article.chars

            media_rows = []
            for ref in article.media:
                rel = ref.member
                if ref.abs_path is not None and media_root is not None:
                    try:
                        rel = str(ref.abs_path.relative_to(media_root))
                    except ValueError:
                        pass
                elif ref.abs_path is not None:
                    rel = str(ref.abs_path)
                media_rows.append((article_id, ref.kind, rel, ref.caption))
            if media_rows:
                conn.executemany(
                    "INSERT INTO media (article_id, kind, rel_path, caption)"
                    " VALUES (?, ?, ?, ?)", media_rows,
                )
                n_media += len(media_rows)

            if article.xrefs:
                conn.executemany(
                    "INSERT INTO xrefs (article_id, target_slug, anchor, ordinal)"
                    " VALUES (?, ?, ?, ?)",
                    [(article_id, target, anchor, i)
                     for i, (target, anchor) in enumerate(article.xrefs)],
                )
                n_xrefs += len(article.xrefs)

        conn.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?)",
            [
                ("schema_version", SCHEMA_VERSION),
                ("tokenizer", tokenizer),
                ("source_label", source_label),
                ("built_at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
                ("article_count", str(n_articles)),
                ("media_count", str(n_media)),
                ("xref_count", str(n_xrefs)),
                ("char_count", str(total_chars)),
                ("media_root", str(media_root) if media_root is not None else ""),
            ],
        )
        conn.commit()
        conn.execute("INSERT INTO articles_fts(articles_fts) VALUES('optimize')")
        conn.commit()
        return {"articles": n_articles, "media": n_media, "xrefs": n_xrefs,
                "chars": total_chars}
    finally:
        conn.close()


def connect_ro(db_path: Path) -> sqlite3.Connection:
    """Open read-only; the app and the query command never mutate a corpus."""
    db_path = Path(db_path).resolve()
    if not db_path.exists():
        raise SystemExit(f"no corpus at {db_path} — run `make ingest` first")
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def meta(conn: sqlite3.Connection) -> dict[str, str]:
    return {row["key"]: row["value"] for row in conn.execute("SELECT key, value FROM meta")}


def tokenizer_of(conn: sqlite3.Connection) -> str:
    return meta(conn).get("tokenizer", "unicode61")


def search(conn: sqlite3.Connection, query: str, limit: int = 20) -> list[sqlite3.Row]:
    """Full-text search, dispatching on the corpus's tokenizer.

    Trigram corpora cannot serve queries shorter than three characters, so those go to a
    `LIKE` scan over the base table — measured behaviour, see docs/ARCHITECTURE.md.
    """
    query = query.strip()
    if not query:
        return []
    columns = "a.id, a.slug, a.title, a.reading, a.category, a.char_count"
    if tokenizer_of(conn) == "trigram" and len(query) < MIN_TRIGRAM_CHARS:
        like = f"%{query}%"
        return conn.execute(
            f"""
            SELECT {columns}, substr(a.body, 1, 120) AS snip
            FROM articles a
            WHERE a.title LIKE ? OR a.reading LIKE ? OR a.body LIKE ?
            ORDER BY length(a.title)
            LIMIT ?
            """,
            (like, like, like, limit),
        ).fetchall()
    return conn.execute(
        f"""
        SELECT {columns}, snippet(articles_fts, 2, '', '', '…', 18) AS snip,
               bm25(articles_fts, 8.0, 4.0, 1.0) AS score
        FROM articles_fts
        JOIN articles a ON a.id = articles_fts.rowid
        WHERE articles_fts MATCH ?
        ORDER BY score
        LIMIT ?
        """,
        (fts_match(query), limit),
    ).fetchall()


def fts_match(query: str) -> str:
    """A forgiving FTS5 MATCH expression: quote the whole query as a phrase.

    Users type prose, not FTS operators, so quoting keeps `-`, `"` and `*` from
    becoming syntax. Works for both tokenizers.
    """
    return '"' + query.replace('"', '""') + '"'


def categories(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT category, COUNT(*) AS n FROM articles GROUP BY category ORDER BY category"
    ).fetchall()


def check(conn: sqlite3.Connection) -> list[str]:
    """Structural sanity checks; returns a list of problems (empty == healthy)."""
    problems: list[str] = []
    info = meta(conn)
    version = info.get("schema_version")
    if version != SCHEMA_VERSION:
        problems.append(f"schema_version {version!r} != expected {SCHEMA_VERSION!r}")
    if info.get("tokenizer") not in TOKENIZERS:
        problems.append(f"unknown tokenizer {info.get('tokenizer')!r}")

    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        problems.append(f"integrity_check: {integrity}")

    n_articles = conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0]
    n_fts = conn.execute("SELECT COUNT(*) FROM articles_fts").fetchone()[0]
    if n_articles != n_fts:
        problems.append(f"fts rows {n_fts} != article rows {n_articles}")
    if n_articles == 0:
        problems.append("corpus has no articles")
    if conn.execute("SELECT COUNT(*) FROM articles WHERE body = ''").fetchone()[0]:
        problems.append("some articles have empty bodies")
    if conn.execute(
        "SELECT COUNT(*) FROM articles WHERE title = slug OR title = ''"
    ).fetchone()[0]:
        # A title identical to the slug means the adapter fell back to the refid, i.e.
        # the source field failed to parse (it carries inline markup, not plain text).
        problems.append("some articles have no parsable title (fell back to their slug)")
    if conn.execute("SELECT COUNT(*) FROM articles WHERE char_count = 0").fetchone()[0]:
        problems.append("some articles have no indexed characters")

    # Dangling cross-references mean the join lost targets; report a count, not a failure.
    dangling = conn.execute(
        "SELECT COUNT(*) FROM xrefs WHERE target_slug NOT IN (SELECT slug FROM articles)"
    ).fetchone()[0]
    if dangling:
        problems.append(f"{dangling} cross-references point outside the corpus")
    return problems
