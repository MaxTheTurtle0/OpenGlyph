#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

configuration=release
architecture_args=()
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=debug ;;
        --universal) architecture_args=(--arch arm64 --arch x86_64) ;;
        *) printf 'Unknown option: %s\nUsage: %s [--debug] [--universal]\n' "$argument" "$0" >&2; exit 2 ;;
    esac
done

app_version="${APP_VERSION:-0.1.0}"
app_version="${app_version#v}"
build_number="${APP_BUILD_NUMBER:-1}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    printf 'APP_VERSION must be x.y.z, and APP_BUILD_NUMBER must be numeric.\n' >&2
    exit 2
fi

swift build -c "$configuration" --product OpenGlyph ${architecture_args[@]+"${architecture_args[@]}"}
binary_directory="$(swift build -c "$configuration" --show-bin-path ${architecture_args[@]+"${architecture_args[@]}"})"
binary_path="$binary_directory/OpenGlyph"
if [[ ! -x "$binary_path" ]]; then
    printf 'Swift build completed without the OpenGlyph executable.\n' >&2
    exit 1
fi

if [[ ! -f Resources/OpenGlyph.icns || scripts/draw-icon.swift -nt Resources/OpenGlyph.icns ]]; then
    ./scripts/generate-icon.sh
fi

mkdir -p build
bundle_stage="$(mktemp -d "$repo_root/build/.app-stage.XXXXXX")"
trap 'rm -rf "$bundle_stage"' EXIT
app_path="$bundle_stage/OpenGlyph.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/OpenGlyph"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/OpenGlyph.icns "$app_path/Contents/Resources/OpenGlyph.icns"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"

# Select a local Developer ID identity when available. This never exports keys.
# Set CODE_SIGN_IDENTITY=- to explicitly use ad-hoc signing, including on CI.
signing_identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n '/"Developer ID Application:/s/.*\([A-F0-9]\{40\}\).*/\1/p' | head -n 1)"
    signing_identity="${signing_identity:--}"
fi
if [[ "$signing_identity" == - ]]; then
    codesign --force --sign - --identifier app.openglyph.mac --timestamp=none \
        --requirements '=designated => identifier "app.openglyph.mac"' "$app_path"
    printf 'Signed ad hoc for local use. Public downloads are not notarized.\n'
else
    codesign --force --sign "$signing_identity" --identifier app.openglyph.mac \
        --options runtime --timestamp "$app_path"
    printf 'Signed with an installed signing identity.\n'
fi
codesign --verify --strict --verbose=2 "$app_path"

rm -rf build/OpenGlyph.app
mv "$app_path" build/OpenGlyph.app
printf 'Built %s/build/OpenGlyph.app (%s, %s)\n' "$repo_root" "$app_version" "$configuration"
