#!/bin/zsh
# Builds build/UltaMac.app (arm64, release), signs it with a stable identity, and optionally
# installs it to /Applications.
#
#   scripts/build-app.sh            local build (arm64), stable signing identity
#   scripts/build-app.sh --install  local build, then copy to /Applications/UltaMac.app
#   scripts/build-app.sh --release  universal (arm64 + x86_64) build for public download,
#                                   strict per-binary signature, zipped to build/UltaMac.zip
#
# Signing: if a "Developer ID Application" or "Apple Development" certificate is in your
# keychain it is used. Otherwise the app is ad-hoc signed with a *designated requirement
# based on the bundle identifier*, so macOS privacy permissions (Full Disk Access, folder
# access) survive rebuilds instead of being reset each time the binary hash changes.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/UltaMac.app
BUNDLE_ID=local.ultamac.app
VERSION=${VERSION:-0.2.0}
MODE=${1:-}

if [[ "$MODE" == "--release" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=(--arch arm64)
fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/UltaMac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UltaMac"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Original sound palette (synthesised by scripts/make-sounds.swift).
if [[ ! -f build/Sounds/success.wav || scripts/make-sounds.swift -nt build/Sounds/success.wav ]]; then
  swift scripts/make-sounds.swift build/Sounds >/dev/null
fi
mkdir -p "$APP/Contents/Resources/Sounds"
cp build/Sounds/*.wav "$APP/Contents/Resources/Sounds/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>UltaMac</string>
  <key>CFBundleDisplayName</key><string>UltaMac</string>
  <key>CFBundleExecutable</key><string>UltaMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleGetInfoString</key><string>UltaMac — The Ultimate Mac Toolkit</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>UltaMac — The Ultimate Mac Toolkit. Clean. Monitor. Optimise. Recover.</string>
  <!-- Shown by macOS in its permission prompts. -->
  <key>NSDesktopFolderUsageDescription</key><string>UltaMac measures your Desktop to show what uses space and to find large, old and duplicate files. Nothing is removed without your review.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>UltaMac measures your Documents folder to show what uses space and to find large, old and duplicate files. Nothing is removed without your review.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>UltaMac looks in Downloads for old installers and large files you may no longer need. Nothing is removed without your review.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>UltaMac reads USB drives so you can inspect, eject, erase or create bootable installers on them.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>UltaMac can measure network volumes you choose to scan. It never sends data anywhere.</string>
  <key>NSAppDataUsageDescription</key><string>UltaMac finds support files other apps left behind so it can uninstall them completely.</string>
  <key>NSSystemAdministrationUsageDescription</key><string>Administrator access is needed only for the single operation you start, such as writing a USB installer.</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ "$MODE" == "--release" ]]; then
  # Public builds: default ad-hoc designated requirement (bound to this exact binary), so no
  # other app can claim UltaMac's identity and inherit the privacy permissions users grant it.
  codesign --force --sign "${IDENTITY:--}" --options runtime --timestamp=none "$APP"
  echo "Release-signed (${IDENTITY:-ad-hoc, binary-bound requirement})"
elif [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --options runtime --timestamp=none --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "Ad-hoc signed with a stable bundle-ID requirement (permissions persist across rebuilds)"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "$MODE" == "--release" ]]; then
  rm -f build/UltaMac.zip
  ditto -c -k --sequesterRsrc --keepParent "$APP" build/UltaMac.zip
  echo "Zipped build/UltaMac.zip"
  shasum -a 256 build/UltaMac.zip
fi

if [[ "$MODE" == "--install" ]]; then
  pkill -x UltaMac 2>/dev/null || true
  rm -rf /Applications/UltaMac.app
  ditto "$APP" /Applications/UltaMac.app
  echo "Installed /Applications/UltaMac.app"
fi
