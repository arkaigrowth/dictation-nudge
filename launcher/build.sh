#!/bin/bash
# Build "Dictation Nudge.app", a tiny launcher for Spotlight, Raycast, or the Dock.
# It is compiled from DictationNudge.applescript in this folder; no binary is
# checked in.
#
#   ./launcher/build.sh                 build into launcher/build/
#   ./launcher/build.sh /Applications   build straight into /Applications
#   ICON=/path/to/icon.png ./launcher/build.sh     use your own 1024px PNG
#   ICON=/path/to/icon.icns ./launcher/build.sh    or a ready-made .icns
#
# Needs only tools that ship with macOS: osacompile, sips, iconutil,
# PlistBuddy, codesign.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$here/build}"
icon="${ICON:-$here/../assets/icon-1024.png}"
app="$dest/Dictation Nudge.app"

[ -f "$icon" ] || { echo "icon not found: $icon" >&2; exit 1; }
mkdir -p "$dest"
if [ -e "$app" ]; then
  echo "Replacing existing $app"
  rm -rf "$app"
fi

osacompile -o "$app" "$here/DictationNudge.applescript"

case "$icon" in
  *.icns)
    cp "$icon" "$app/Contents/Resources/applet.icns"
    ;;
  *)
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    iconset="$work/applet.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
      sips -z "$size" "$size" "$icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
      sips -z "$((size * 2))" "$((size * 2))" "$icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/applet.icns"
    ;;
esac

plist="$app/Contents/Info.plist"
# osacompile points CFBundleIconName at the stock script icon inside
# Assets.car, and that wins over applet.icns. Drop the key so ours shows.
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
# No Dock icon while the launcher runs (it exits within a moment anyway).
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$plist"

# Editing the bundle invalidates osacompile's signature; re-sign ad hoc.
codesign --force --sign - "$app" 2>/dev/null
codesign --verify --strict "$app"

echo "Built $app"
