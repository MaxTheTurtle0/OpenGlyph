# Verification of 0.1.0

Verified on 11 October 2026. Development host: Apple M4 Mac mini, macOS 27.0.1. Installation target: Apple M3 MacBook Air, macOS 27.0.1, reached through the user's existing tailnet and SSH configuration.

## Completed checks

- `swift test`: 31 tests passed on the development host and GitHub's macOS runner, including actual Apple Vision recognition and locally generated fixtures.
- `swift test --build-system native`: all 31 tests passed on the M3 MacBook Air with Swift 6.4 / Xcode 27, using the unchanged source. See the toolchain limitation below.
- Text OCR with line breaks, flattened output, accurate/fast modes, language availability, and web-link classification.
- QR payload precedence, Code128 barcodes, PNG/JPEG/TIFF/HEIC imports, EXIF orientation, and rotated PDF pages.
- Multi-page PDFs with blank-page skipping, locked PDFs, file/page limits, local history bounds, persistence failures, and settings reload.
- Nine capture geometry tests, including actual pixel checks for vertically stacked, staggered, and mixed Retina/1x displays. Fragments retain their orientation, and gaps stay blank.
- Native and universal release builds. Both arm64 and x86_64 slices have macOS 14 deployment targets.
- Bundle signatures, extracted ZIP integrity, ZIP/DMG SHA-256 checksums, and safe installer behavior.
- Native SwiftUI menu, settings, onboarding, and detail screens rendered and visually inspected in light and dark appearances.
- Running app on the development host imported a file and a QR code, recognized text, wrote the expected clipboard content, and persisted history. A clipboard image invoked through `openglyph://clipboard` passed the same pipeline.
- Release archive transferred to the MacBook Air. Its checksum and installed app signature verified there. App installed at `~/Applications/OpenGlyph.app`, launched in the logged-in user's session, and reported version 0.1.0 with the expected Vision languages.
- The Air's installed executable recognized text and QR fixtures. Its running app imported text fixtures from files and the clipboard, copied the results, and persisted history. Native interface previews were rendered on the Air.
- Source checkout at `~/code/OpenGlyph` registered as the OpenGlyph project in T3 Code on the MacBook Air.
- Independent source review resolved paste-focus restoration, multi-display composition, login-item approval visibility, and shortcut recording/conflict issues. Final assessment found no material code defects, with live interaction checks pending.

## Developer toolchain limitation

The Air's default Swift 6.4 SwiftBuild test host failed nine accurate-Vision checks with an Apple `e5rt` compute error. Running the unchanged suite with Swift's native build system passed all 31 checks. The failing test bundle reported linked SDK 14.0; the passing native test bundle reported SDK 27.0. This difference may explain the failure, but its cause is not established. No assertions were skipped, and no recognition-engine downgrade was added.

First accurate recognition requests on the Air also waited for Apple's local Neural Engine model compiler. The installed app's standalone recognition completed successfully after compilation. These delays and the test-host failure are recorded separately from app acceptance.

## Manual acceptance still needed

Screen Recording permission was not granted at verification time. Native UI automation returned `Sky Computer Use service startup request failed`, so no automated mouse-drag acceptance is claimed.

On the MacBook Air:

1. Complete onboarding and enable OpenGlyph in macOS Screen & System Audio Recording. Reopen the app if macOS asks.
2. With a text field active in another app, press Command-Shift-2, select readable screen text, then paste. Confirm the original app regains focus.
3. Start a capture and cancel with Escape, then right-click. Confirm normal cursor/focus returns.
4. Set a custom shortcut. Try a conflicting shortcut and confirm the error stays visible and the previous shortcut still works.
5. Try a QR code, clipboard image, and PDF through the menu. Search, filter, copy, view full text, remove one history item, and clear history.
6. If desired, enable launch at login, approve it in macOS Login Items, and confirm after logging in again.
7. On a multi-monitor setup, test a selection on each screen and across screens.

Intel binaries compile, but runtime acceptance on an Intel Mac has not been performed. Windows and Linux are not implemented. Public archives are ad-hoc signed and are not Apple-notarized.
