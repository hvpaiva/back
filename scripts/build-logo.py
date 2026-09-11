#!/usr/bin/env python3
"""Draw the BACK lab logo: four official CNCF icons around the Kubernetes helm.

The icons are the published ones, fetched from cncf/artwork and embedded with
their own paths untouched; only their ids and CSS classes get a prefix, so
several files can live in one SVG. This script decides nothing about the
drawings themselves, only where they sit.

Usage: python3 scripts/build-logo.py [output.svg]
"""
import math
import pathlib
import re
import sys
import tempfile
import urllib.request

ARTWORK = "https://raw.githubusercontent.com/cncf/artwork/main/projects/{0}/icon/{1}/{0}-icon-{1}.svg"
CACHE = pathlib.Path(tempfile.gettempdir()) / "back-logo-icons"

# prefix: (icon, viewBox crop to the drawing, gradient light -> dark)
ICONS = {
    "bs": ("backstage-white", "0 0 337.46 428.50", ("#2BB39E", "#178A79")),
    "ar": ("argo-white", "0 0 522 673", ("#F57A3D", "#D9501F")),
    "xp": ("crossplane-white", "232 40 436 820", ("#E35B8A", "#BE3268")),
    "ky": ("kyverno-white", "8 40 484 434", ("#3F86D1", "#2562A8")),
}
CENTRE = ("#5A6677", "#3B4554")  # neutral, so blue belongs to Kyverno alone

C = 64  # centre of the 128 x 128 canvas
HEX_RADIUS = 53  # polygon radius; the rounded stroke adds CORNER around it
CORNER = 10
CUT_WIDTH = 5  # gap between the four pieces
HEPT_RADIUS = 12  # the Kubernetes piece
HEPT_ROUND = 6
HOLE_STROKE = HEPT_ROUND + 2 * CUT_WIDTH  # same gap as the cuts, all around
WHEEL_RADIUS = 0.8 * (HEPT_RADIUS * math.cos(math.pi / 7) + HEPT_ROUND / 2)

# Room around the mark, so it never touches the edge of a favicon, an app icon
# or a README image. The hexagon reaches the canvas at top and bottom.
MARGIN = 10

# Icon size and offset from the centre, the same in all four pieces so the set
# reads as one. 28.9 is the largest size that keeps every icon at least 3 units
# clear of the border, the cuts and the centre, measured against each icon's
# rasterised silhouette rather than its bounding box.
ICON_SIZE = 28.9
ICON_OFFSET = (27.0, 25.0)

# One curved cut from the centre outwards; the other three are its quarter
# turns, which is what makes the pinwheel.
CUT = ((8, -30), (0, -72))
# piece: (cut going out, outer corner, cut coming back, which side of centre)
PIECES = {
    "bs": ("up", (-72, -72), "left", (-1, -1)),
    "ar": ("right", (72, -72), "up", (1, -1)),
    "ky": ("down", (72, 72), "right", (1, 1)),
    "xp": ("left", (-72, 72), "down", (-1, 1)),
}


def fetch(name):
    """The official icon, from the local cache or from cncf/artwork."""
    CACHE.mkdir(exist_ok=True)
    path = CACHE / f"{name}.svg"
    if not path.exists():
        project, variant = name.rsplit("-", 1) if name.endswith("-white") else (name, "color")
        with urllib.request.urlopen(ARTWORK.format(project, variant)) as response:
            path.write_bytes(response.read())
    return path.read_text()


def load(prefix):
    name = ICONS[prefix][0]
    src = re.sub(r"<\?xml.*?\?>", "", fetch(name)).strip()
    attrs, body = re.match(r"<svg([^>]*)>(.*)</svg>\s*$", src, re.S).groups()
    fill = re.search(r'\sfill="([^"]+)"', attrs)
    body = re.sub(r"\bcls-", f"{prefix}-cls-", body)
    body = re.sub(r'id="', f'id="{prefix}-', body)
    body = re.sub(r"url\(#", f"url(#{prefix}-", body)
    body = re.sub(r'href="#', f'href="#{prefix}-', body)
    return f' fill="{fill.group(1)}"' if fill else "", body


def place(prefix, cx, cy):
    viewbox = ICONS[prefix][1]
    _, _, vw, vh = map(float, viewbox.split())
    aspect = vw / vh
    w, h = (aspect * ICON_SIZE, ICON_SIZE) if aspect < 1 else (ICON_SIZE, ICON_SIZE / aspect)
    fill, body = load(prefix)
    return (
        f'<svg x="{cx - w / 2:.2f}" y="{cy - h / 2:.2f}" width="{w:.2f}" height="{h:.2f}" '
        f'viewBox="{viewbox}" preserveAspectRatio="xMidYMid meet"{fill}>{body}</svg>'
    )


def helm():
    """The white helm of the official Kubernetes icon, without its rim."""
    path = re.findall(r'<path d="([^"]+)"', fetch("kubernetes"))[-1]
    size = 2 * WHEEL_RADIUS
    return (
        f'<svg x="{C - size / 2:.2f}" y="{C - size / 2:.2f}" width="{size:.2f}" height="{size:.2f}" '
        f'viewBox="39 39 154 154"><path d="{path}" fill="#fff"/></svg>'
    )


def gradient(gid, light, dark):
    return (
        f'<linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{light}"/><stop offset="1" stop-color="{dark}"/></linearGradient>'
    )


def rot(v, turns):
    x, y = v
    for _ in range(turns):
        x, y = -y, x
    return x, y


def pt(v):
    return f"{C + v[0]:g} {C + v[1]:g}"


def polygon(sides, radius):
    step = 360 / sides
    return " ".join(
        f"{C + radius * math.cos(math.radians(-90 + k * step)):.2f},"
        f"{C + radius * math.sin(math.radians(-90 + k * step)):.2f}"
        for k in range(sides)
    )


def logo():
    cuts = {name: tuple(rot(v, turns) for v in CUT) for turns, name in enumerate(["up", "right", "down", "left"])}
    hexagon = polygon(6, HEX_RADIUS)
    heptagon = polygon(7, HEPT_RADIUS)
    cut_paths = "".join(f'<path d="M{C} {C} Q{pt(ctrl)} {pt(end)}"/>' for ctrl, end in cuts.values())

    s = "<defs>" + "".join(gradient(f"g-{p}", *ICONS[p][2]) for p in PIECES) + gradient("g-k8", *CENTRE)
    s += (
        '<mask id="pieces"><rect width="128" height="128" fill="#000"/>'
        f'<polygon points="{hexagon}" fill="#fff" stroke="#fff" stroke-width="{CORNER * 2}" stroke-linejoin="round"/>'
        f'<g fill="none" stroke="#000" stroke-width="{CUT_WIDTH}" stroke-linecap="round">{cut_paths}</g>'
        f'<polygon points="{heptagon}" fill="#000" stroke="#000" stroke-width="{HOLE_STROKE}" stroke-linejoin="round"/>'
        "</mask></defs>"
        '<g mask="url(#pieces)">'
    )
    for prefix, (out, corner, back, _) in PIECES.items():
        (ctrl_out, end_out), (ctrl_back, end_back) = cuts[out], cuts[back]
        s += (
            f'<path d="M{C} {C} Q{pt(ctrl_out)} {pt(end_out)} L{pt(corner)} '
            f'L{pt(end_back)} Q{pt(ctrl_back)} {C} {C}Z" fill="url(#g-{prefix})"/>'
        )
    s += "</g>"

    dx, dy = ICON_OFFSET
    for prefix, (*_, (sx, sy)) in PIECES.items():
        s += place(prefix, C + sx * dx, C + sy * dy)

    s += (
        f'<polygon points="{heptagon}" fill="url(#g-k8)" stroke="url(#g-k8)" '
        f'stroke-width="{HEPT_ROUND}" stroke-linejoin="round"/>'
    )
    return s + helm()


out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "logo.svg")
out.write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
    f'viewBox="{-MARGIN} {-MARGIN} {128 + 2 * MARGIN} {128 + 2 * MARGIN}" '
    f'width="{128 + 2 * MARGIN}" height="{128 + 2 * MARGIN}">{logo()}</svg>\n'
)
print(f"wrote {out}")
