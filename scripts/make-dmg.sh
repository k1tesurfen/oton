#!/bin/bash
# make-dmg.sh <oton.app> <out.dmg>            build the DMG (no Finder involved)
# make-dmg.sh --layout <oton.app> <out.dmg>   let Finder lay out the window once and save it as
#                                             Resources/dmg/DS_Store (opens a Finder window briefly)
# Contents: oton.app, an Applications link and the Alfred workflow on a background with the steps.
# The volume is always named "oton", so the saved layout (which points at the background by volume name)
# fits every version.
set -euo pipefail
cd "$(dirname "$0")/.."
LAYOUT=0
if [ "${1:-}" = "--layout" ]; then LAYOUT=1; shift; fi
APP=$1; OUT=$2
VOL="oton"
TEMPLATE=Resources/dmg/DS_Store
TMP=$(mktemp -d)
STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/oton.app"
ln -s /Applications "$STAGE/Applications"
cp build/oton.alfredworkflow "$STAGE/oton.alfredworkflow"
# Retina background: 1x + 2x in one TIFF.
rsvg-convert -w 640 -h 440 Resources/dmg/background.svg -o "$TMP/bg.png"
rsvg-convert -w 1280 -h 880 Resources/dmg/background.svg -o "$TMP/bg@2x.png"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
if [ $LAYOUT = 0 ]; then
  [ -s $TEMPLATE ] || { echo "no $TEMPLATE yet: run scripts/make-dmg.sh --layout once"; exit 1; }
  cp $TEMPLATE "$STAGE/.DS_Store"
fi

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$TMP/rw.dmg"
# -nobrowse: the volume doesn't appear on the desktop or in Finder's sidebar while we work on it.
NOBROWSE=-nobrowse; [ $LAYOUT = 1 ] && NOBROWSE=
DEV=$(hdiutil attach -readwrite -noverify -noautoopen $NOBROWSE "$TMP/rw.dmg" | awk '/Apple_HFS/ {print $1}')
cp Resources/oton.icns "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL"
SetFile -a V "/Volumes/$VOL/.background" "/Volumes/$VOL/.VolumeIcon.icns"

if [ $LAYOUT = 1 ]; then
  # Tiling window managers resize the Finder window; pause AeroSpace while Finder saves the layout.
  AERO=0; if command -v aerospace >/dev/null && pgrep -x AeroSpace >/dev/null; then aerospace enable off && AERO=1; fi
  rm -f "/Volumes/$VOL/.DS_Store"
  osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 80
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "oton.app" of container window to {170, 165}
    set position of item "Applications" of container window to {470, 165}
    set position of item "oton.alfredworkflow" of container window to {320, 305}
    try
      set position of item ".background" of container window to {900, 900}
    end try
    try
      set position of item ".VolumeIcon.icns" of container window to {1000, 900}
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  for _ in $(seq 1 20); do [ -s "/Volumes/$VOL/.DS_Store" ] && break; sleep 0.5; done
  [ $AERO = 1 ] && aerospace enable on
  [ -s "/Volumes/$VOL/.DS_Store" ] || { echo "Finder didn't write the layout"; exit 1; }
  cp "/Volumes/$VOL/.DS_Store" $TEMPLATE
  echo "saved $TEMPLATE"
fi
rm -rf "/Volumes/$VOL/.fseventsd"
sync
hdiutil detach "$DEV" -quiet
rm -f "$OUT"
hdiutil convert -quiet "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$TMP"
echo "$OUT ($(du -h "$OUT" | cut -f1))"
