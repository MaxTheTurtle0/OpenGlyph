#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
skip_build=false
launch_app=true
for argument in "$@"; do
    case "$argument" in
        --skip-build) skip_build=true ;;
        --no-open) launch_app=false ;;
        *) printf 'Unknown option: %s\nUsage: %s [--skip-build] [--no-open]\n' "$argument" "$0" >&2; exit 2 ;;
    esac
done

if [[ "$skip_build" == false ]]; then
    "$repo_root/scripts/build-app.sh"
fi
source_app="$repo_root/build/OpenGlyph.app"
if [[ ! -x "$source_app/Contents/MacOS/OpenGlyph" ]]; then
    printf 'No built app found. Run ./scripts/build-app.sh first.\n' >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$source_app"
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
if [[ "$actual_identifier" != app.openglyph.mac ]]; then
    printf 'Refusing to install an app with an unexpected bundle identifier.\n' >&2
    exit 1
fi

install_root="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$install_root"
install_root="$(cd "$install_root" && pwd -P)"
destination="$install_root/OpenGlyph.app"
if [[ -L "$destination" ]]; then
    printf 'Refusing to replace a symbolic link at %s.\n' "$destination" >&2
    exit 1
fi
if [[ -e "$destination" ]]; then
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_identifier" != app.openglyph.mac ]]; then
        printf 'Refusing to replace a different application at %s.\n' "$destination" >&2
        exit 1
    fi
fi
install_stage="$(mktemp -d "$install_root/.openglyph-install.XXXXXX")"
cleanup() {
    if [[ ! -e "$destination" && -e "$install_stage/previous.app" ]]; then
        mv "$install_stage/previous.app" "$destination"
    fi
    rm -rf "$install_stage"
}
trap cleanup EXIT
ditto "$source_app" "$install_stage/OpenGlyph.app"
codesign --verify --strict --verbose=2 "$install_stage/OpenGlyph.app"

# Pass the destination before moving it. SSH sessions may not see GUI apps via
# NSRunningApplication, so the helper also checks exact same-user executable paths.
xcrun swift "$repo_root/scripts/terminate-app.swift" "$destination/Contents/MacOS/OpenGlyph"
if [[ -e "$destination" || -L "$destination" ]]; then
    mv "$destination" "$install_stage/previous.app"
fi
mv "$install_stage/OpenGlyph.app" "$destination"
registration_tool=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$registration_tool" ]]; then
    "$registration_tool" -f "$destination"
fi
printf 'Installed %s\n' "$destination"
if [[ "$launch_app" == true ]]; then
    open "$destination"
    printf 'OpenGlyph is running in the menu bar.\n'
fi
