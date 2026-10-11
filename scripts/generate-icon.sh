#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/openglyph-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT

xcrun swift "$repo_root/scripts/draw-icon.swift" "$icon_work/OpenGlyph.iconset"
iconutil -c icns "$icon_work/OpenGlyph.iconset" -o "$icon_work/OpenGlyph.icns"
cp "$icon_work/OpenGlyph.icns" "$repo_root/Resources/OpenGlyph.icns"
cp "$icon_work/OpenGlyph-icon.png" "$repo_root/Resources/OpenGlyph-icon.png"
printf 'Generated Resources/OpenGlyph.icns and Resources/OpenGlyph-icon.png\n'
