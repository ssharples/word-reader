#!/bin/bash
# Builds "Word Reader.app" into build/.
#
#   Scripts/build-app.sh            build only
#   Scripts/build-app.sh --install  build, then copy to ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product WordReader
binary="$(swift build -c release --show-bin-path)/WordReader"

app="build/Word Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/WordReader"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The icon is drawn by a script, so make it once and reuse it.
if [ ! -f build/AppIcon.icns ]; then
  iconset="build/AppIcon.iconset"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  swift Scripts/make-icon.swift build/icon-1024.png
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
  rm -rf "$iconset"
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate when there is one: the app then keeps
# the same identity between builds, so macOS remembers its iCloud Drive permission.
# Otherwise sign for this Mac only. Set SIGN_IDENTITY to choose a certificate.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')}"
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" "$app"
  echo "Built $app (signed with your Apple Development certificate)"
else
  codesign --force --sign - "$app"
  echo "Built $app (signed for this Mac only)"
fi

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Word Reader.app"
  cp -R "$app" "$HOME/Applications/"
  echo "Installed to ~/Applications/Word Reader.app"
fi
