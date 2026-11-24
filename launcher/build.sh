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

# Only ever replace a launcher this script built. Anything else that happens
# to sit at the destination under that name is left alone.
if [ -e "$app" ] || [ -L "$app" ]; then
  name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ -L "$app" ] || [ "$name" != "Dictation Nudge" ] || [ ! -f "$app/Contents/Resources/Scripts/main.scpt" ]; then
    echo "refusing to replace $app: it is not a launcher built by this script" >&2
    exit 1
  fi
fi

# Build in a scratch folder and move the result into place at the end, so a
# failed build never costs you the launcher you already have.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
final="$app"
app="$work/Dictation Nudge.app"

osacompile -o "$app" "$here/DictationNudge.applescript"

case "$icon" in
  *.icns)
    cp "$icon" "$app/Contents/Resources/applet.icns"
    ;;
  *)
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

mkdir -p "$dest"
if [ -e "$final" ]; then
  echo "Replacing existing $final"
  rm -rf "$final"
fi
mv "$app" "$final"

echo "Built $final"
