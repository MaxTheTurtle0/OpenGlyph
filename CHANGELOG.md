# Changes

## 0.1.1

- Recover from recurring Apple Vision `TextRecognition.CRImageReaderError error 1` with bounded local backup recognition. Show a notice when backup recognition is used.
- Normalize screen and imported images to opaque 8-bit sRGB, pad tight crops, and skip uniform images.
- Remove app activation and window animation when selection starts. Use ScreenCaptureKit's pixel scale for scaled Retina displays.
- Cancel selection on deliberate app switches without restoring the previous app over the user's choice.
- Detect the installed app's process over SSH and stop it before replacing the bundle.
- Add repeated-crop, image-format, backup-language, tiny-image, and scaled-display regression checks. All 46 tests pass on the tested MacBook Air and Mac mini.

## 0.1.0

- Initial macOS app with screen, clipboard, image, PDF, QR, and barcode recognition; local history; configurable shortcuts; and permission onboarding.
