#!/usr/bin/env python3
# Render the Sniplet app icon from vector source; this script is the icon's source of truth.
# Concept: a selection frame (four corner brackets) with a brand-green piece lifted out of it.
# Requires rsvg-convert (brew install librsvg).
# Usage: scripts/render-app-icon.py            writes AppIcon.appiconset and website/public/icon.png
#        (the website copy is cropped to the tile, without the macOS grid margin or shadow)
#        scripts/render-app-icon.py --svg DIR  also keeps the generated SVG masters in DIR
import math
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Sniplet/Resources/Assets.xcassets/AppIcon.appiconset"
WEBSITE_ICON = ROOT / "website/public/icon.png"

INK = "#1B2B25"


def squircle(cx, cy, size, n=5.0, steps=720):
    """Continuous-corner tile on the 824 pt macOS icon grid (1024 canvas)."""
    a = size / 2
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / n), c)
        y = cy + a * math.copysign(abs(s) ** (2 / n), s)
        points.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(points) + " Z"


TILE = squircle(512, 512, 824)


def brackets(x0, y0, x1, y1, arm, width):
    r = width / 2
    paths = [
        f"M{x0},{y0 + arm} L{x0},{y0 + r} Q{x0},{y0} {x0 + r},{y0} L{x0 + arm},{y0}",
        f"M{x1 - arm},{y0} L{x1 - r},{y0} Q{x1},{y0} {x1},{y0 + r} L{x1},{y0 + arm}",
        f"M{x1},{y1 - arm} L{x1},{y1 - r} Q{x1},{y1} {x1 - r},{y1} L{x1 - arm},{y1}",
        f"M{x0 + arm},{y1} L{x0 + r},{y1} Q{x0},{y1} {x0},{y1 - r} L{x0},{y1 - arm}",
    ]
    return "".join(
        f'<path d="{p}" fill="none" stroke="{INK}" stroke-width="{width}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>' for p in paths)


def icon(small=False, web=False):
    """`small` is the 16/32 px artwork: heavier brackets and no card shadow or sheen.
    `web` crops to the tile and drops its shadow, for favicons and the site header."""
    width, arm = (84, 168) if small else (56, 140)
    card = '<rect x="362" y="242" width="420" height="420" rx="76" fill="url(#card)"/>'
    details = "" if small else (
        '<rect x="362" y="242" width="420" height="420" rx="76" fill="url(#sheen)"/>'
        '<rect x="362" y="242" width="420" height="420" rx="76" fill="none" '
        'stroke="#FFFFFF" stroke-opacity="0.20" stroke-width="3"/>')
    tile = f'<path d="{TILE}" fill="url(#tile)"/>'
    viewbox = "100 100 824 824" if web else "0 0 1024 1024"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="{viewbox}">
<defs>
<filter id="tileShadow" x="-20%" y="-20%" width="140%" height="140%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="10"/>
  <feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
  <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="cardShadow" x="-40%" y="-40%" width="180%" height="180%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="18"/><feOffset dy="14"/>
  <feComponentTransfer><feFuncA type="linear" slope="0.28"/></feComponentTransfer>
  <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E8EFEA"/></linearGradient>
<linearGradient id="card" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#25A983"/><stop offset="1" stop-color="#0F5E48"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/><stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
</defs>
{tile if web else f'<g filter="url(#tileShadow)">{tile}</g>'}
<path d="{TILE}" fill="none" stroke="{INK}" stroke-opacity="0.10" stroke-width="{4 if small else 2}"/>
{brackets(242, 302, 722, 782, arm, width)}
{card if small else f'<g filter="url(#cardShadow)">{card}</g>'}
{details}
</svg>
'''


def render(svg_path, size, out):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(out)], check=True)


def main():
    keep = pathlib.Path(sys.argv[sys.argv.index("--svg") + 1]) if "--svg" in sys.argv else None
    with tempfile.TemporaryDirectory() as tmp:
        masters = pathlib.Path(keep or tmp)
        masters.mkdir(parents=True, exist_ok=True)
        regular, small = masters / "AppIcon.svg", masters / "AppIcon-small.svg"
        web = masters / "AppIcon-web.svg"
        regular.write_text(icon())
        small.write_text(icon(small=True))
        web.write_text(icon(web=True))
        for size in (16, 32, 64, 128, 256, 512, 1024):
            render(small if size <= 32 else regular, size, ICONSET / f"icon-{size}.png")
        render(web, 512, WEBSITE_ICON)
    print(f"Wrote {ICONSET.relative_to(ROOT)} and {WEBSITE_ICON.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
