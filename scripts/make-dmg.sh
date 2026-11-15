#!/bin/zsh
# Packages build/UltaMac.app into build/UltaMac.dmg with an "drag to Applications" layout.
# Run scripts/build-app.sh --release first. Background art: scripts/make-readme-art.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/UltaMac.app
BG=${BG:-docs/images/dmg-background.png}
OUT=build/UltaMac.dmg
STAGE=$(mktemp -d)
RW=$(mktemp -u).dmg
VOL="UltaMac"

[[ -d "$APP" ]] || { echo "Build the app first: scripts/build-app.sh --release"; exit 1; }

ditto "$APP" "$STAGE/UltaMac.app"
ln -s /Applications "$STAGE/Applications"
if [[ -f "$BG" ]]; then
  mkdir "$STAGE/.background"
  # 1x + 2x combined so the background is sharp on Retina displays.
  sips -z 400 660 "$BG" --out "$STAGE/.background/bg1x.png" >/dev/null
  cp "$BG" "$STAGE/.background/bg2x.png"
  tiffutil -cathidpicheck "$STAGE/.background/bg1x.png" "$STAGE/.background/bg2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
  rm "$STAGE/.background/bg1x.png" "$STAGE/.background/bg2x.png"
fi
cp build/AppIcon.icns "$STAGE/.VolumeIcon.icns"

hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size 80m "$RW"
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MNT" 2>/dev/null || true

# Window layout via Finder (needs Automation permission; skipped gracefully if denied).
if [[ -f "$BG" ]]; then
  if ! timeout 30 osascript <<OSA 2>"$STAGE.err" >/dev/null
tell application "Finder"
  tell disk "$(basename "$MNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "UltaMac.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  then
    echo "Note: Finder layout skipped ($(cat "$STAGE.err" 2>/dev/null)). The DMG still works."
  fi
fi

sync
hdiutil detach -quiet "$MNT" || hdiutil detach -force "$MNT"
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$STAGE" "$RW"
echo "Created $OUT"
shasum -a 256 "$OUT"
