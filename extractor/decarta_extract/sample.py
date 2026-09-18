"""Sample corpus: a tiny hand-written stand-in for a 2000s DVD encyclopedia.

Kept deliberately small and copyright-clean so the repo is usable with no disc.
Regenerate with `python3 -m decarta_extract sample`.
"""

from __future__ import annotations

import base64
from pathlib import Path

# 2x2 opaque PNG — enough to exercise the media manifest.
PNG_2X2 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8DAwMDAxMDAwMAABAAA"
    "/wAAAP//AwAqLwLzAAAAAElFTkSuQmCC"
)

PAGES: dict[str, tuple[str, str]] = {
    "Earth Science/volcano.html": (
        "Volcano",
        """<html><head><title>Volcano - World Encyclopedia 2003</title></head><body>
        <h1>Volcano</h1>
        <p>A volcano is a rupture in the crust of a planetary-mass object that allows hot
        lava, volcanic ash and gases to escape from a magma chamber below the surface.</p>
        <p>On Earth, volcanoes are most often found where tectonic plates are diverging or
        converging, and most are found underwater. The Decade Volcanoes list names sixteen
        volcanoes singled out for study because of their destructive history.</p>
        <p>Volcanic eruptions can be classified as Hawaiian, Strombolian, Vulcanian,
        Peléan or Plinian. The 1883 eruption of Krakatoa was heard nearly 5,000 km away.</p>
        </body></html>""",
    ),
    "Earth Science/earthquake.html": (
        "Earthquake",
        """<html><head><title>Earthquake</title></head><body>
        <h1>Earthquake</h1>
        <p>An earthquake is the shaking of the surface of the Earth resulting from a sudden
        release of energy in the lithosphere that creates seismic waves.</p>
        <p>Seismic magnitude is measured on the moment magnitude scale, which replaced the
        older Richter scale for large events. Intensity is described by the Mercalli scale.</p>
        </body></html>""",
    ),
    "Astronomy/solar-system.html": (
        "Solar System",
        """<html><head><title>Solar System</title></head><body>
        <h1>Solar System</h1>
        <p>The Solar System comprises the Sun and the objects that orbit it: eight planets,
        dwarf planets such as Pluto, moons, asteroids and comets.</p>
        <p>Mercury, Venus, Earth and Mars are the terrestrial planets. Jupiter and Saturn
        are gas giants; Uranus and Neptune are ice giants.</p>
        </body></html>""",
    ),
    "Astronomy/comet.html": (
        "Comet",
        """<html><head><title>Comet</title></head><body>
        <h1>Comet</h1>
        <p>A comet is a small icy body that, when passing close to the Sun, warms and
        releases gases, producing a visible coma and sometimes a tail.</p>
        <p>Halley's Comet returns roughly every 76 years; its 1986 apparition was the first
        observed by spacecraft.</p>
        </body></html>""",
    ),
    "Technology/microprocessor.html": (
        "Microprocessor",
        """<html><head><title>Microprocessor</title></head><body>
        <h1>Microprocessor</h1>
        <p>A microprocessor is a computer processor for which the data processing logic and
        control is included on a single integrated circuit.</p>
        <p>The 4004 (1971) packed the equivalent of 2,300 transistors; by the time this
        encyclopedia shipped, desktop processors already held tens of millions.</p>
        </body></html>""",
    ),
    # Decoy: a frameset landing page that must NOT become an article.
    "index.html": (
        "World Encyclopedia 2003",
        """<html><head><title>World Encyclopedia 2003</title></head><body>
        <frameset><frame src="nav.html"><frame src="Earth Science/volcano.html"></frameset>
        </body></html>""",
    ),
}


def write_sample(root: Path) -> int:
    root = Path(root)
    written = 0
    for rel, (title, markup) in PAGES.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(markup, encoding="utf-8")
        written += 1
    # Sibling image for one entry, to exercise the media manifest.
    image = root / "Earth Science" / "volcano.png"
    if not image.exists():
        image.write_bytes(PNG_2X2)
    return written