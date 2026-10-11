#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
skip_build=false
make_dmg=false
build_options=()
for argument in "$@"; do
    case "$argument" in
        --skip-build) skip_build=true ;;
        --dmg) make_dmg=true ;;
        --universal) build_options=(--universal) ;;
        *) printf 'Unknown option: %s\nUsage: %s [--skip-build] [--dmg] [--universal]\n' "$argument" "$0" >&2; exit 2 ;;
    esac
done
if [[ "$skip_build" == true && ${#build_options[@]} -gt 0 ]]; then
    printf '%s\n' '--universal cannot be combined with --skip-build.' >&2
    exit 2
fi
if [[ "$skip_build" == false ]]; then
    ./scripts/build-app.sh ${build_options[@]+"${build_options[@]}"}
fi

app_path="$repo_root/build/OpenGlyph.app"
codesign --verify --strict --verbose=2 "$app_path"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
architectures="$(lipo -archs "$app_path/Contents/MacOS/OpenGlyph")"
if [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]; then
    architecture=universal
elif [[ "$architectures" == *arm64* ]]; then
    architecture=arm64
else
    architecture=x86_64
fi
archive_name="OpenGlyph-$app_version-macos-$architecture"
archive_directory="$repo_root/build/dist"
mkdir -p "$archive_directory"
zip_path="$archive_directory/$archive_name.zip"
rm -f "$zip_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
(
    cd "$archive_directory"
    shasum -a 256 "$archive_name.zip" > "$archive_name.zip.sha256"
)

if [[ "$make_dmg" == true ]]; then
    dmg_stage="$(mktemp -d "$repo_root/build/.dmg-stage.XXXXXX")"
    trap 'rm -rf "$dmg_stage"' EXIT
    ditto "$app_path" "$dmg_stage/OpenGlyph.app"
    ln -s /Applications "$dmg_stage/Applications"
    cp "$repo_root/LICENSE" "$dmg_stage/LICENSE.txt"
    hdiutil create -volname OpenGlyph -srcfolder "$dmg_stage" -ov -format UDZO "$archive_directory/$archive_name.dmg"
    (
        cd "$archive_directory"
        shasum -a 256 "$archive_name.dmg" > "$archive_name.dmg.sha256"
    )
fi
printf 'Packaged %s\n' "$zip_path"
