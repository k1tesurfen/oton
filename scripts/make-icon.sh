#!/bin/bash
# Renders Resources/icon/oton.svg into Resources/oton.icns (needs rsvg-convert: brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")/.."
SET=$(mktemp -d)/oton.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s Resources/icon/oton.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) Resources/icon/oton.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/oton.icns
rsvg-convert -w 512 -h 512 Resources/icon/oton.svg -o Resources/icon/oton.png
echo Resources/oton.icns
