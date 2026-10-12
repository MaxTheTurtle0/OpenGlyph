# Architecture

OpenGlyph is a Swift package with two targets and no third-party dependencies.

`OpenGlyphCore` owns recognition, history, settings, links, and screen geometry. `OCRService` uses Vision for text and barcode recognition, ImageIO for image orientation, and CoreGraphics for PDF rendering. `HistoryStore` saves bounded local JSON with atomic writes. `AppSettings` persists preferences in UserDefaults. `CaptureGeometry` crops and composes screenshots independently of the UI, with pixel regression tests.

Recognition keeps decoded input and intermediate request lifetimes within their own autorelease pools. `OCRRecoveryPolicy` stores a bounded process-local failure history by language configuration. Two consecutive known compute failures recovered by Fast within two minutes activate a one-minute cooldown. Fast-only captures do not extend that cooldown. The next capture after expiry tries Accurate again. Accurate success and unrelated errors clear the failure history. The policy stores no images, recognized text, or persistent settings.

`OpenGlyph` is the menu bar executable. `AppController` coordinates imports, clipboard output, history, native windows, login registration, and URL commands. `CaptureCoordinator` takes in-memory ScreenCaptureKit snapshots of connected displays before presenting an AppKit drag overlay. It closes overlays and restores the previously active app before delivering results. `GlobalHotKey` uses Carbon to register a shortcut without Accessibility permission.

SwiftUI renders the menu, settings, onboarding, details, and a short clipboard toast. Recognition runs in detached tasks so the main thread remains responsive. Custom shortcut recording suspends the global hotkey until registration completes. Conflicting shortcuts restore the previous setting and report the error.

Packaging scripts create an app bundle, generate original icon artwork, sign the bundle, create distribution archives, and install a verified bundle. The installer can replace only the same app identifier and keeps the previous bundle available for rollback until installation succeeds.

Windows and Linux ports need replacements for AppKit, ScreenCaptureKit, Carbon, ServiceManagement, and Vision. A port should preserve the local history format and offline recognition behavior.
