#!/usr/bin/env bash
# Regenerates the iOS app icon set (app/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset)
# from the Icon Composer source, app/src-tauri/icons/FrameMate.icon.
#
# The .icon's liquid-glass rendering needs iOS 18+ and Xcode 16; the app targets iOS 16, so this
# flattens it instead: the layer's SVG at its scale, centred, over the icon's background gradient,
# as an opaque full-bleed square (iOS rounds the corners itself). Only the iOS icon comes from
# here — Android, desktop and the in-app logo keep upstream's artwork.
#
# Needs macOS (Quick Look renders the SVG with WebKit) and ImageMagick (`brew install imagemagick`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/app/src-tauri/icons/FrameMate.icon"
SET="$ROOT/app/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset"
command -v magick >/dev/null || { echo "!! ImageMagick not found — 'brew install imagemagick'." >&2; exit 1; }
command -v qlmanage >/dev/null || { echo "!! qlmanage not found (macOS only)." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# icon.json -> one 1024x1024 SVG: gradient background + the (first) layer's artwork.
python3 -I - "$SOURCE" "$WORK/master.svg" <<'PY'
import json, re, sys
src, out = sys.argv[1], sys.argv[2]
icon = json.load(open(f"{src}/icon.json"))

def hex_color(spec):  # "srgb:r,g,b,a" or "extended-srgb:…" -> #rrggbb
    r, g, b = (float(v) for v in spec.split(":", 1)[1].split(",")[:3])
    return "#" + "".join(f"{round(max(0, min(1, c)) * 255):02x}" for c in (r, g, b))

S = 1024
fill = icon.get("fill", {})
stops = fill.get("linear-gradient") or [fill.get("solid", "srgb:0,0,0,1")] * 2
o = fill.get("orientation", {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}})
layer = icon["groups"][0]["layers"][0]
art = open(f"{src}/Assets/{layer['image-name']}").read()
view = re.search(r'viewBox="([^"]+)"', art).group(1)
inner = re.sub(r"(?s)^.*?<svg[^>]*>|</svg>\s*$", "", art)
scale = layer.get("position", {}).get("scale", 1.0)
dx, dy = layer.get("position", {}).get("translation-in-points", [0, 0])
size = S * scale
x, y = (S - size) / 2 + dx, (S - size) / 2 + dy
open(out, "w").write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">
  <defs><linearGradient id="bg" gradientUnits="userSpaceOnUse"
    x1="{o['start']['x'] * S}" y1="{o['start']['y'] * S}" x2="{o['stop']['x'] * S}" y2="{o['stop']['y'] * S}">
    <stop offset="0" stop-color="{hex_color(stops[0])}"/><stop offset="1" stop-color="{hex_color(stops[-1])}"/>
  </linearGradient></defs>
  <rect width="{S}" height="{S}" fill="url(#bg)"/>
  <svg x="{x}" y="{y}" width="{size}" height="{size}" viewBox="{view}">{inner}</svg>
</svg>''')
PY

# ImageMagick's own SVG renderer drops gradients and nested SVG; Quick Look (WebKit) doesn't.
qlmanage -t -s 1024 -o "$WORK" "$WORK/master.svg" >/dev/null 2>&1
[ -f "$WORK/master.svg.png" ] || { echo "!! Quick Look did not render the icon." >&2; exit 1; }
magick "$WORK/master.svg.png" -resize 1024x1024! -alpha remove -alpha off "$WORK/master.png"

# Every slot named in the set's Contents.json, at its pixel size, opaque (no alpha on iOS icons).
python3 -I - "$SET/Contents.json" <<'PY' > "$WORK/slots"
import json, sys
for image in json.load(open(sys.argv[1]))["images"]:
    if "filename" in image:
        points = float(image["size"].split("x")[0])
        print(image["filename"], round(points * int(image["scale"].rstrip("x"))))
PY
while read -r file px; do
  magick "$WORK/master.png" -resize "${px}x${px}" -background black -alpha remove -alpha off \
    -define png:color-type=2 -strip "$SET/$file"
done < "$WORK/slots"
echo "==> Rendered $(wc -l < "$WORK/slots" | tr -d ' ') icons into $SET"
