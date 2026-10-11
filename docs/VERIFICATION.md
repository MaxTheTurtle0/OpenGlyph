# Verification of 0.1.1

Verified on 11 October 2026. Development host: Apple M4 Mac mini, macOS 27.0.1. Installation target: Apple M3 MacBook Air, macOS 27.0.1, reached through the user's existing tailnet and SSH configuration.

## Recognition failure and recovery

The user reported recurring `TextRecognition.CRImageReaderError error 1` after successful screen captures. The Air's running app and test suite reproduced it. Apple's accurate recognition backend logged `e5rt` compute error 13. The underlying Apple failure is not fixed by this application.

OpenGlyph now renders input into an owned, opaque 8-bit sRGB bitmap, pads tight crops, and rejects uniform images before recognition. For known accurate-engine compute errors, it attempts compatible accurate recognition, then Fast recognition. Recovery is bounded to three requests. Cancellation and unrelated errors are not retried. Explicit language choices are preserved; if a backup cannot support the chosen language, the original failure remains an error.

The app labels backup results. Fast recovery can be less accurate and supports fewer languages. Automatic backup uses supported preferred languages. Tests retain a punctuation case that Fast misreads, and confirm that malformed output stays plain text rather than becoming an openable URL.

The Air can spend 35–90 seconds initializing Apple's accurate engine on its first request. Subsequent compute failures recover quickly. In the installed running app, six serial tight-crop imports passed with correct history and clipboard text. The first measured import took 8.28 seconds after an earlier initialization request; the following five took 0.33–0.34 seconds each. Logs confirmed backup recognition handled the recurring Apple failure.

## Capture activation changes

Selection uses nonactivating panels with window animation disabled, and no longer activates OpenGlyph before showing the overlay. The previous app stays active. ScreenCaptureKit's own content rectangle and pixel scale determine screenshot dimensions, without mixing in AppKit's backing scale. This addresses desktop movement and scaling during activation, including the Air's scaled Retina display mode.

## Completed checks

- `swift test`: all 46 tests passed on the development host.
- On the M3 MacBook Air with Swift 6.4 / Xcode 27, all 46 tests passed with both `swift test` and `swift test --build-system native`. No assertions were skipped.
- Repeated tight BGRA/P3 crops, HDR pixels, transparent input, and tiny uniform images exercised the recovery and preparation paths.
- Text OCR with line breaks, flattened output, accurate/fast modes, language availability, backup notices, and web-link classification.
- QR payload precedence, Code128 barcodes, PNG/JPEG/TIFF/HEIC imports, EXIF orientation, and rotated PDF pages.
- Multi-page PDFs with blank-page skipping, locked PDFs, file/page limits, local history bounds, persistence failures, and settings reload.
- Twelve capture geometry tests, including exact pixel checks for vertically stacked, staggered, and mixed Retina/1x displays, plus screenshot sizing for scaled displays. Fragments retain orientation, and gaps stay blank.
- Native and universal release builds. Both arm64 and x86_64 slices have macOS 14 deployment targets.
- Bundle signatures, extracted ZIP integrity, and ZIP/DMG SHA-256 checksums.
- SSH installer detection verified against the Air's unchanged running process. Isolated native process tests terminated only the exact target, preserved a same-name sibling, and refused replacement when a target ignored SIGTERM. The refusal preserved the existing executable and cleaned staging; a relative installation directory also passed.
- Native SwiftUI menu, settings, onboarding, and detail screens rendered and visually inspected in light and dark appearances. The new backup notice was rendered and checked for layout.
- Version 0.1.1 archive transferred to the MacBook Air, checksum verified, installed at `~/Applications/OpenGlyph.app`, and signature verified. After explicitly restarting the previous process, the new running process mapped the installed executable.
- The Air's installed running app recognized six serial file imports, copied the expected text, and persisted history. Earlier file, QR, and clipboard-image acceptance also passed on 0.1.0.
- Source checkout at `~/code/OpenGlyph` registered as the OpenGlyph project in T3 Code on the MacBook Air.
- Independent source review found no material code defects in the recognition and activation fixes. Live interaction checks remain separate from source and fixture checks.

## Manual acceptance

The user granted Screen Recording permission and performed real screen captures before reporting the failure. An SSH-launched diagnostics process can report a different permission context; that result does not establish the running GUI app's permission.

Native UI automation returned `Sky Computer Use service startup request failed`. Automated drag, focus, cancellation, and visual activation acceptance are therefore not claimed. On the MacBook Air:

1. With another app active, press Command-Shift-2 several times and select readable screen text. Confirm recognition succeeds and the desktop stays still when selection begins.
2. Paste into the original app and confirm focus is retained.
3. Start a capture and cancel with Escape, then right-click. Confirm normal cursor and focus return.
4. Switch apps or Spaces during selection. Confirm selection cancels without undoing the switch.
5. Set a custom shortcut. Try a conflicting shortcut and confirm the error remains visible and the previous shortcut still works.
6. Try a QR code, clipboard image, and PDF through the menu. Search, filter, copy, view full text, and remove a test history item.
7. If desired, enable launch at login, approve it in macOS Login Items, and confirm after logging in again.
8. On a multi-monitor setup, test a selection on each screen and across screens.

Intel binaries compile, but runtime acceptance on an Intel Mac has not been performed. Windows and Linux are not implemented. Public archives are ad-hoc signed and are not Apple-notarized.
