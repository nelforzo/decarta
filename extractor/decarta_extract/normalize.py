"""Normalization helpers: legacy HTML -> plain text, slugs, category labels."""

from __future__ import annotations

import html
import re
import unicodedata
from html.parser import HTMLParser

# Tags whose *content* is never article text.
DROP_CONTENT = {"script", "style", "head", "noscript", "template"}
# Tags that imply a paragraph/line break in the flat text.
BLOCK_TAGS = {
    "p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
    "table", "blockquote", "section", "article", "hr", "td", "pre",
}
# Directories that hold assets, not articles.
ASSET_DIRS = {"images", "image", "img", "media", "assets", "data", "_derived", "help"}
_WS = re.compile(r"[^\S\n]+")
_BLANKS = re.compile(r"\n{3,}")
_NUMERIC_SHARD = re.compile(r"^\d{1,3}$")


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.chunks: list[str] = []
        self.headings: list[tuple[int, str]] = []
        self.title = ""
        self._drop_depth = 0
        self._in_title = False
        self._heading: tuple[int, list[str]] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in DROP_CONTENT:
            self._drop_depth += 1
        elif tag == "title":
            self._in_title = True
        elif tag in {"h1", "h2", "h3"}:
            self._heading = (int(tag[1]), [])
        if tag in BLOCK_TAGS:
            self.chunks.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in DROP_CONTENT and self._drop_depth:
            self._drop_depth -= 1
        elif tag == "title":
            self._in_title = False
        elif tag in {"h1", "h2", "h3"} and self._heading is not None:
            level, parts = self._heading
            text = " ".join(parts).strip()
            if text:
                self.headings.append((level, text))
            self._heading = None
        if tag in BLOCK_TAGS:
            self.chunks.append("\n")

    def handle_data(self, data: str) -> None:
        if self._drop_depth:
            return
        if self._in_title:
            self.title += data
            return
        if self._heading is not None:
            self._heading[1].append(data)
        self.chunks.append(data)


def html_to_text(markup: str) -> tuple[str, str, list[tuple[int, str]]]:
    """Return (text, <title> contents, [(level, heading)] for h1..h3)."""
    parser = _TextExtractor()
    parser.feed(markup)
    parser.close()
    text = html.unescape("".join(parser.chunks))
    text = _WS.sub(" ", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    return _BLANKS.sub("\n\n", text).strip(), parser.title.strip(), parser.headings


def pick_title(path_stem: str, headings: list[tuple[int, str]], page_title: str) -> str:
    """Best-effort entry title: first h1, then <title>, then heading, then filename."""
    for level, text in headings:
        if level == 1:
            return _clean_title(text)
    if page_title:
        return _clean_title(page_title)
    if headings:
        return _clean_title(headings[0][1])
    return _clean_title(path_stem.replace("_", " ").replace("-", " "))


def _clean_title(text: str) -> str:
    text = _WS.sub(" ", text).strip()
    # "VOLCANO - Encyclopedia 2003" and "Volcano | Home" style suffixes.
    for sep in (" - ", " | ", " :: ", " — "):
        if sep in text:
            head, _, tail = text.partition(sep)
            if head.strip() and len(head.strip()) >= 3:
                return head.strip()
    return text


def slugify(title: str) -> str:
    normalized = unicodedata.normalize("NFKD", title)
    ascii_only = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_only).strip("-")
    return slug or "entry"


def category_for(relative_parts: tuple[str, ...]) -> str:
    """Closest meaningful ancestor directory, else 'Uncategorized'."""
    for part in reversed(relative_parts[:-1]):
        low = part.lower()
        if low in ASSET_DIRS or _NUMERIC_SHARD.match(low):
            continue
        return part.replace("_", " ").strip().title()
    return "Uncategorized"


def word_count(text: str) -> int:
    return len(text.split())


def char_count(text: str) -> int:
    """Characters excluding whitespace.

    Whitespace token counts are meaningless for CJK (a whole article is a handful of
    "words"), so the corpus stores this instead — see docs/ARCHITECTURE.md.
    """
    return sum(1 for ch in text if not ch.isspace())


# 五十音 rows, hiragana. Voiced kana decompose via NFKD into a base kana + mark, so
# they land in their row automatically (が -> か, ぱ -> は).
_AICU_ROWS: list[tuple[str, str]] = [
    ("あ行", "あいうえおぁぃぅぇぉ"),
    ("か行", "かきくけこゕゖ"),
    ("さ行", "さしすせそ"),
    ("た行", "たちつてとっ"),
    ("な行", "なにぬねの"),
    ("は行", "はひふへほ"),
    ("ま行", "まみむめも"),
    ("や行", "やゆよゃゅょ"),
    ("ら行", "らりるれろ"),
    ("わ行", "わをんゎゐゑ"),
]
_ROW_OF = {ch: row for row, chars in _AICU_ROWS for ch in chars}


def _kana_row(ch: str) -> str | None:
    base = unicodedata.normalize("NFKD", ch)[0]
    code = ord(base)
    if 0x30A1 <= code <= 0x30F6:  # katakana -> hiragana
        code -= 0x60
    return _ROW_OF.get(chr(code))


def aicu_bucket(*candidates: str) -> str:
    """五十音 browse bucket from a reading/title.

    Articles on this disc carry no taxonomy, so the browse axis is derived from the kana
    reading (`<jtitle>`). That field starts with the *display* title, so the kana usually
    sits after it: prefer a leading kana or an ASCII/digit head, and otherwise fall
    through to the first kana anywhere in the string (the reading).
    """
    deferred: str | None = None
    for text in candidates:
        if not text:
            continue
        chars = [ch for ch in text.strip() if not ch.isspace()]
        if not chars:
            continue
        head = unicodedata.normalize("NFKD", chars[0])[0]
        row = _kana_row(chars[0])
        if row:
            return row
        if head.isascii() and head.isalpha():
            return "A–Z"
        if head.isdigit():
            return "0–9"
        if deferred is None:
            for ch in chars[1:]:
                row = _kana_row(ch)
                if row:
                    deferred = row
                    break
    return deferred or "その他"


def reading_from(title: str, jtitle: str) -> str:
    """The disc's reading field, minus the leading repeat of the display title."""
    text = unicodedata.normalize("NFKC", jtitle or "").strip()
    text = " ".join(text.split())
    if not text:
        return ""
    flat_title = " ".join(unicodedata.normalize("NFKC", title or "").split())
    if flat_title and text.startswith(flat_title):
        text = text[len(flat_title):].strip()
    return text


def snip(text: str, words: int = 24) -> str:
    """Short preview line for CLI listings."""
    flat = _WS.sub(" ", text.replace("\n", " ")).strip()
    parts = flat.split()
    if len(parts) <= words:
        return flat
    return " ".join(parts[:words]) + "…"