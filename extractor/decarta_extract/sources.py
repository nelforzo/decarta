"""Source adapters: walk a disc tree (or write the sample corpus) into Articles."""

from __future__ import annotations

import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

from .normalize import category_for, html_to_text, pick_title, slugify, word_count

HTML_SUFFIXES = {".htm", ".html", ".xhtml"}
MEDIA_SUFFIXES = {".jpg", ".jpeg", ".png", ".gif", ".mov", ".avi", ".mp3", ".wav", ".m4a"}
SKIP_DIRS = {"images", "image", "img", "media", "assets", "_derived", "help", ".git"}
MAX_HTML_BYTES = 8 * 1024 * 1024  # refuse to slurp CD-sized junk as an entry


@dataclass
class MediaRef:
    kind: str
    abs_path: Path
    caption: str = ""


@dataclass
class Article:
    slug: str
    title: str
    body: str
    category: str
    source_path: str
    media: list[MediaRef] = field(default_factory=list)

    @property
    def words(self) -> int:
        return word_count(self.body)


def _decode(raw: bytes) -> str:
    """2000s discs are a soup of encodings; try the likely ones, never fail."""
    for enc in ("utf-8", "windows-1252", "shift_jis", "euc-jp", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def generic_html(root: Path, media_out: Path | None = None) -> Iterator[Article]:
    """Adapter for HTML-tree discs (frameset index + per-entry pages)."""
    root = Path(root)
    seen_slugs: dict[str, int] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in HTML_SUFFIXES:
            continue
        rel = path.relative_to(root)
        if any(part.lower() in SKIP_DIRS for part in rel.parts[:-1]):
            continue
        try:
            if path.stat().st_size > MAX_HTML_BYTES:
                continue
            raw = path.read_bytes()
        except OSError:
            continue

        text, page_title, headings = html_to_text(_decode(raw))
        title = pick_title(path.stem, headings, page_title)
        if not title or len(text) < 40:
            continue  # index/landing/stub page, not an entry

        slug = slugify(title)
        if slug in seen_slugs:
            seen_slugs[slug] += 1
            slug = f"{slug}-{seen_slugs[slug]}"
        else:
            seen_slugs[slug] = 1

        article = Article(
            slug=slug,
            title=title,
            body=text,
            category=category_for(rel.parts),
            source_path=str(rel),
        )
        if media_out is not None:
            article.media = _sibling_media(path, root, media_out)
        yield article


def _sibling_media(page: Path, root: Path, media_out: Path) -> list[MediaRef]:
    """Copy same-stem assets next to the page into media_out and reference them."""
    refs: list[MediaRef] = []
    for candidate in sorted(page.parent.glob(f"{page.stem}.*")):
        if candidate == page or candidate.suffix.lower() not in MEDIA_SUFFIXES:
            continue
        rel = candidate.relative_to(root)
        dest = media_out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists():
            shutil.copy2(candidate, dest)
        kind = {"jpg": "image", "jpeg": "image", "png": "image", "gif": "image",
                "mov": "video", "avi": "video"}.get(candidate.suffix.lstrip(".").lower(), "audio")
        refs.append(MediaRef(kind=kind, abs_path=dest, caption=""))
    return refs


ADAPTERS: dict[str, Callable[..., Iterator[Article]]] = {
    "generic-html": generic_html,
}


def get_adapter(name: str) -> Callable[..., Iterator[Article]]:
    try:
        return ADAPTERS[name]
    except KeyError:
        raise SystemExit(
            f"unknown adapter {name!r}; available: {', '.join(sorted(ADAPTERS))}"
        ) from None