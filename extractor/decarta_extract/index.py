"""Corpus builder: SQLite + FTS5 index over normalized articles."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from .sources import Article

SCHEMA_VERSION = "1"

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
    body        TEXT NOT NULL,
    category    TEXT NOT NULL,
    source_path TEXT NOT NULL,
    word_count  INTEGER NOT NULL
);

CREATE TABLE media (
    id         INTEGER PRIMARY KEY,
    article_id INTEGER NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL,
    rel_path   TEXT NOT NULL,
    caption    TEXT NOT NULL DEFAULT ''
);

CREATE INDEX idx_articles_category ON articles(category);
CREATE INDEX idx_articles_title ON articles(title);
CREATE INDEX idx_media_article ON media(article_id);

CREATE VIRTUAL TABLE articles_fts USING fts5(
    title,
    body,
    content='articles',
    content_rowid='id',
    tokenize="unicode61 remove_diacritics 2"
);

CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
END;

CREATE TRIGGER articles_au AFTER UPDATE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body)
    VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO articles_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
"""


def build(articles: Iterable[Article], db_path: Path, *, source_label: str,
          media_root: Path | None = None, replace: bool = True) -> dict[str, int]:
    """Write a corpus. Returns counts; caller decides what to log."""
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if replace and db_path.exists():
        for suffix in ("", "-wal", "-shm"):
            sidecar = db_path.with_name(db_path.name + suffix)
            sidecar.unlink(missing_ok=True)

    conn = sqlite3.connect(db_path)
    try:
        conn.executescript(SCHEMA)
        n_articles = n_media = total_words = 0
        for article in articles:
            cur = conn.execute(
                "INSERT INTO articles (slug, title, body, category, source_path, word_count)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (article.slug, article.title, article.body, article.category,
                 article.source_path, article.words),
            )
            article_id = int(cur.lastrowid or 0)
            n_articles += 1
            total_words += article.words
            for ref in article.media:
                rel = ref.abs_path
                if media_root is not None:
                    try:
                        rel = ref.abs_path.relative_to(media_root)
                    except ValueError:
                        pass
                conn.execute(
                    "INSERT INTO media (article_id, kind, rel_path, caption) VALUES (?, ?, ?, ?)",
                    (article_id, ref.kind, str(rel), ref.caption),
                )
                n_media += 1

        conn.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?)",
            [
                ("schema_version", SCHEMA_VERSION),
                ("source_label", source_label),
                ("built_at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
                ("article_count", str(n_articles)),
                ("media_count", str(n_media)),
                ("word_count", str(total_words)),
            ],
        )
        conn.commit()
        conn.execute("INSERT INTO articles_fts(articles_fts) VALUES('optimize')")
        conn.commit()
        return {"articles": n_articles, "media": n_media, "words": total_words}
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


def search(conn: sqlite3.Connection, query: str, limit: int = 20) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT a.id, a.slug, a.title, a.category, a.word_count,
               snippet(articles_fts, 1, '', '', '…', 18) AS snip,
               bm25(articles_fts, 8.0, 1.0) AS score
        FROM articles_fts
        JOIN articles a ON a.id = articles_fts.rowid
        WHERE articles_fts MATCH ?
        ORDER BY score
        LIMIT ?
        """,
        (query, limit),
    ).fetchall()


def categories(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT category, COUNT(*) AS n FROM articles GROUP BY category ORDER BY category"
    ).fetchall()


def meta(conn: sqlite3.Connection) -> dict[str, str]:
    return {row["key"]: row["value"] for row in conn.execute("SELECT key, value FROM meta")}


def check(conn: sqlite3.Connection) -> list[str]:
    """Structural sanity checks; returns a list of problems (empty == healthy)."""
    problems: list[str] = []
    version = meta(conn).get("schema_version")
    if version != SCHEMA_VERSION:
        problems.append(f"schema_version {version!r} != expected {SCHEMA_VERSION!r}")

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
    if conn.execute("SELECT COUNT(*) FROM articles WHERE title = ''").fetchone()[0]:
        problems.append("some articles have empty titles")
    return problems