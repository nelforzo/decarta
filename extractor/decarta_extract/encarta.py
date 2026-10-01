"""`encarta-its` adapter: read the encyclopedia out of the disc's ITSS containers.

The disc stores no readable files. Its payload is 64 Microsoft InfoTech Storage
containers (`.ITS`, same family as `.CHM`) whose members are LZX-compressed. 7-Zip opens
them by signature, so this adapter shells out to it rather than reimplementing LZX; see
`docs/DISC-SOURCES.md` for the container layout and the measured timings.

Shape of the data (verified, see docs/DISC-SOURCES.md):

* ``EE/ENCARTA/DATASTD.ITS`` -> ``data/<refid>.xml``: one record per object, tagged with
  a group (``article``, ``media``, ``weblink``, …). Article records carry ``<title>`` and
  the kana reading ``<jtitle>``; media records carry ``<files>`` asset references and a
  ``<caption>``. ``<forward>``/``<reverse>`` blocks hold ``<assoc refid group>`` links.
* ``CONTENT/CONTSTD.ITS`` -> ``content/<refid>.xml``: the bodies, UTF-8 XML with
  ``<pkey>`` paragraphs, ``<section>``/``<sectiontitle>`` structure and ``<xref>``
  cross-references.

Everything is joined by the numeric ``refid``, which is already ASCII and stable, so it
is used as the slug.
"""

from __future__ import annotations

import shutil
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

from .normalize import aicu_bucket, reading_from
from .sources import Article, MediaRef

# 7-Zip, newest name first. `7zz` reads .ITS by signature (it reports them as `Hxs`).
SEVEN_ZIP_CANDIDATES = ("7zz", "7z", "7za")

# Container locations relative to the disc root.
CATALOG_CONTAINER = "EE/ENCARTA/DATASTD.ITS"
BODY_CONTAINER = "CONTENT/CONTSTD.ITS"
# Partial text for the other SKUs; merged only when the Standard container lacks a body.
EXTRA_BODY_CONTAINERS = ("CONTENT/CONTDLX.ITS", "CONTENT/CONTEWA.ITS")
# Media byte containers (member -> container index).
MEDIA_CONTAINER_PATTERNS = ("CONTENT/MED*.ITS", "CONTENT/PICON*.ITS",
                            "CONTENT/THUMB*.ITS", "CONTENT/SW*.ITS")

# Only formats a modern reader can display/play without proprietary decoders.
CONVERTIBLE_MEDIA = {".jpg", ".jpeg", ".png", ".gif", ".wav", ".wma", ".mp3",
                     ".m4a", ".mov", ".avi", ".wmv", ".mid", ".bmp"}
# `<files>` children we turn into manifest rows. `<ticon>` is deliberately absent: it is
# the same handful of generic type icons on every record, not article content.
ASSET_KINDS = {"image": "image", "thumb": "thumbnail", "picon": "thumbnail"}

INLINE_SKIP = {"inlinebmp", "bmp", "image", "picon", "thumb", "ticon", "sec", "formula"}
BLOCK_TAGS = {"pkey", "sectiontitle", "headline", "listitem", "quote", "author",
              "list", "p", "div", "br", "li"}


class ItsError(RuntimeError):
    pass


def find_seven_zip() -> str:
    for name in SEVEN_ZIP_CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
    raise ItsError(
        "no 7-Zip binary found (looked for "
        + ", ".join(SEVEN_ZIP_CANDIDATES)
        + "); install it with `brew install sevenzip`"
    )


def _run(args: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(args, capture_output=True, check=False)


def list_members(container: Path) -> list[str]:
    """Enumerate a container's members without decompressing anything."""
    result = _run([find_seven_zip(), "l", "-slt", str(container)])
    if result.returncode != 0:
        raise ItsError(f"7-Zip could not list {container}: {result.stderr.decode(errors='replace')[:200]}")
    members: list[str] = []
    for raw in result.stdout.decode("utf-8", "replace").splitlines():
        if raw.startswith("Path = "):
            name = raw[len("Path = "):].strip()
            if name and name != str(container):
                members.append(name.replace("\\", "/"))
    return members


def extract_members(container: Path, dest: Path, members: list[str] | None = None) -> None:
    """Extract a container (or a subset of members) into `dest`."""
    dest.mkdir(parents=True, exist_ok=True)
    args = [find_seven_zip(), "x", "-y", "-bso0", "-bsp0", f"-o{dest}", str(container)]
    if members:
        args.extend(members)
    result = _run(args)
    if result.returncode != 0:
        raise ItsError(f"7-Zip could not extract {container}: {result.stderr.decode(errors='replace')[:200]}")


def ensure_extracted(container: Path, scratch: Path) -> Path:
    """Extract `container` into `scratch/<stem>` once, reusing an existing tree.

    Re-decoding 1.4 GB of containers per ingest would dominate the run, so the scratch
    tree is keyed by container name and reused when present. The adapter stays
    deterministic: the *corpus* depends only on the disc, never on scratch state.
    """
    dest = scratch / container.stem
    marker = dest / ".extracted"
    if marker.exists():
        return dest
    if dest.exists():
        shutil.rmtree(dest)
    extract_members(container, dest)
    marker.write_text(container.name, encoding="utf-8")
    return dest


# --------------------------------------------------------------------------- records


def _tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1].lower()


def _inline_text(element: ET.Element) -> str:
    """All descendant text of an element, for fields that carry inline markup.

    Titles, readings and captions are not plain strings: they wrap content in
    `<fs>`/`<tbd>`/`<it>`/`<sup>`/`<inf>` directives, so reading `.text` alone yields
    either nothing or a prefix truncated at the first nested tag.
    """
    parts: list[str] = []
    if element.text:
        parts.append(element.text)
    for child in element:
        parts.append(" " if _tag(child) == "break" else _inline_text(child))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


@dataclass
class DataRecord:
    refid: str
    group: str
    title: str = ""
    jtitle: str = ""
    caption: str = ""
    files: list[tuple[str, str]] = field(default_factory=list)   # (kind, member)
    forward: list[tuple[str, str]] = field(default_factory=list)  # (refid, group)
    reverse: list[tuple[str, str]] = field(default_factory=list)


def parse_catalog(path: Path) -> dict[str, DataRecord]:
    records: dict[str, DataRecord] = {}
    for xml_file in path.glob("data/*.xml"):
        try:
            root = ET.fromstring(xml_file.read_bytes())
        except ET.ParseError:
            continue
        if _tag(root) != "data":
            continue
        refid = root.get("refid") or xml_file.stem
        record = DataRecord(refid=refid, group=(root.get("group") or "").lower())
        for child in root:
            tag = _tag(child)
            if tag == "title":
                record.title = _inline_text(child).strip()
            elif tag == "jtitle":
                record.jtitle = _inline_text(child).strip()
            elif tag == "caption":
                record.caption = _inline_text(child).strip()
            elif tag == "files":
                for asset in child:
                    holder = (asset.text or "").strip()
                    if not holder:
                        continue
                    # "msencdata::baggage/<member>": keep the member's full path, which
                    # is what 7-Zip addresses inside the media containers.
                    member = holder.split("msencdata::", 1)[-1]
                    if member:
                        record.files.append((_tag(asset), member.replace("\\", "/")))
            elif tag in ("forward", "reverse"):
                seen = record.forward if tag == "forward" else record.reverse
                for assoc in child:
                    if _tag(assoc) != "assoc":
                        continue
                    target = assoc.get("refid")
                    if target:
                        seen.append((target, (assoc.get("group") or "").lower()))
        records[refid] = record
    return records


class _BodyParser:
    """Flatten a body's XML into paragraphs, recording cross-references."""

    def __init__(self) -> None:
        self.blocks: list[str] = []
        self.xrefs: list[tuple[str, str]] = []
        self._buffer: list[str] = []

    def _flush(self) -> None:
        text = "".join(self._buffer).strip()
        if text:
            self.blocks.append(text)
        self._buffer = []

    def walk(self, element: ET.Element) -> None:
        tag = _tag(element)
        if tag == "break":
            self._buffer.append(" ")
            return
        if tag in INLINE_SKIP:
            return
        if tag == "xref":
            refid = element.get("RefID") or element.get("refid") or ""
            label = unicodedata.normalize("NFKC", _inline_text(element)).strip()
            if refid and label:
                self.xrefs.append((refid, label))
            self._buffer.append(label)
            return
        if tag in BLOCK_TAGS:
            self._flush()
            self._walk_children(element)
            self._flush()
            return
        self._walk_children(element)

    def _walk_children(self, element: ET.Element) -> None:
        if element.text:
            self._buffer.append(element.text)
        for child in element:
            self.walk(child)
            if child.tail:
                self._buffer.append(child.tail)

    def text(self) -> str:
        self._flush()
        cleaned = []
        for block in self.blocks:
            flat = " ".join(unicodedata.normalize("NFKC", block).split())
            if flat:
                cleaned.append(flat)
        return "\n\n".join(cleaned)


def parse_body(xml_bytes: bytes) -> tuple[str, list[tuple[str, str]]]:
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return "", []
    parser = _BodyParser()
    parser.walk(root)
    return parser.text(), parser.xrefs


# --------------------------------------------------------------------------- adapter


def _locate(root: Path, relative: str) -> Path | None:
    candidate = root / relative
    if candidate.exists():
        return candidate
    # Be forgiving about case on case-insensitive volumes / different mounts.
    parts = relative.split("/")
    current = root
    for part in parts:
        match = next((child for child in current.iterdir()
                      if child.name.lower() == part.lower()), None) if current.is_dir() else None
        if match is None:
            return None
        current = match
    return current


def _media_index(root: Path) -> dict[str, str]:
    """member name -> container path, built from one listing pass over media containers."""
    index: dict[str, str] = {}
    containers: list[Path] = []
    for pattern in MEDIA_CONTAINER_PATTERNS:
        containers.extend(sorted(root.glob(pattern)))
    seen: set[Path] = set()
    for container in containers:
        if container in seen:
            continue
        seen.add(container)
        for member in list_members(container):
            name = member.rsplit("/", 1)[-1]
            index.setdefault(member, str(container))
            index.setdefault(name, str(container))
    return index


def encarta_its(root: Path, media_out: Path | None = None, *,
                scratch: Path | None = None, copy_media: bool = True,
                limit: int = 0) -> Iterator[Article]:
    """Yield every article on the disc, joined from catalog + body containers."""
    root = Path(root)
    if not root.is_dir():
        raise ItsError(f"disc tree not found: {root}")

    scratch = Path(scratch) if scratch else (Path.cwd() / "build" / "its-scratch")
    scratch.mkdir(parents=True, exist_ok=True)

    catalog_container = _locate(root, CATALOG_CONTAINER)
    body_container = _locate(root, BODY_CONTAINER)
    if catalog_container is None or body_container is None:
        raise ItsError(
            f"not an Encarta 2003 disc tree: expected {CATALOG_CONTAINER} and "
            f"{BODY_CONTAINER} under {root}"
        )

    catalog_tree = ensure_extracted(catalog_container, scratch)
    body_tree = ensure_extracted(body_container, scratch)

    records = parse_catalog(catalog_tree)

    # Bodies, plus the other-SKU containers for anything Standard lacks. Those are
    # optional: a container that 7-Zip cannot open is skipped, not fatal.
    bodies: dict[str, tuple[str, list[tuple[str, str]]]] = {}
    body_roots = [body_tree]
    for relative in EXTRA_BODY_CONTAINERS:
        extra = _locate(root, relative)
        if extra is None:
            continue
        try:
            body_roots.append(ensure_extracted(extra, scratch))
        except ItsError:
            continue
    for body_root in body_roots:
        for xml_file in body_root.glob("content/*.xml"):
            refid = xml_file.stem
            if refid in bodies:
                continue
            bodies[refid] = parse_body(xml_file.read_bytes())

    media_index: dict[str, str] | None = None
    if media_out is not None and copy_media:
        media_out.mkdir(parents=True, exist_ok=True)
        media_index = _media_index(root)

    article_refids = {refid for refid, rec in records.items() if rec.group == "article"}
    emitted = 0
    for refid in sorted(records, key=lambda value: (len(value), value)):
        record = records[refid]
        if record.group != "article":
            continue
        body, xrefs = bodies.get(refid, ("", []))
        if not body:
            continue

        article = Article(
            slug=refid,
            title=record.title or refid,
            body=body,
            category=aicu_bucket(record.jtitle, record.title),
            source_path=f"content/{refid}.xml",
            reading=reading_from(record.title, record.jtitle),
        )
        # Only article-to-article references are navigable in the reader; an xref to a
        # sidebar/table/media record stays as plain text in the body.
        article.xrefs = [(target, label) for target, label in xrefs
                         if target in article_refids]
        article.media = _article_media(record, records)
        if media_index is not None and media_out is not None:
            _copy_media(article.media, media_index, media_out)

        emitted += 1
        yield article
        if limit and emitted >= limit:
            return


def _article_media(record: DataRecord, records: dict[str, DataRecord]) -> list[MediaRef]:
    """Resolve the article's ``<assoc group="media">`` links to asset members.

    Pure and disc-independent: the manifest is built from the catalog alone, so a
    corpus can list the media it references without the bytes being copied.
    """
    refs: list[MediaRef] = []
    seen: set[str] = set()
    for target, group in record.forward:
        if group != "media" or target in seen:
            continue
        seen.add(target)
        media_record = records.get(target)
        if media_record is None:
            continue
        caption = media_record.title or media_record.caption
        for kind, member in media_record.files:
            role = ASSET_KINDS.get(kind)
            if role is None:
                continue
            suffix = Path(member).suffix.lower()
            display = role if suffix in CONVERTIBLE_MEDIA else "thumbnail"
            refs.append(MediaRef(kind=display, member=member, caption=caption))
    return refs


def _copy_media(refs: list[MediaRef], media_index: dict[str, str], media_out: Path) -> None:
    """Extract the referenced members that a reader can display, in place."""
    for ref in refs:
        if ref.kind != "image" or ref.abs_path is not None:
            continue
        container = media_index.get(ref.member) or media_index.get(Path(ref.member).name)
        if not container:
            continue
        dest = media_out / Path(ref.member)
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                extract_members(Path(container), media_out, [ref.member])
            except ItsError:
                continue
        if dest.exists():
            ref.abs_path = dest
