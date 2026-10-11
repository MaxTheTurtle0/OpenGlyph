# OpenGlyph

A free, open-source macOS menu bar app that copies text from your screen. Press Command-Shift-2, drag over text or a QR code, then paste. Recognition uses Apple Vision on your Mac.

Inspired by the workflow of [Letra](https://getletra.app/). OpenGlyph is an independent implementation with its own code and artwork, licensed under MIT.

## Requirements

macOS 14 or later. Building requires Xcode command line tools and Swift 5.9 or later. No accounts, API keys, or cloud services.

## Development

```sh
swift test
./scripts/build-app.sh
./scripts/install.sh
```

macOS is the initial supported platform. Apple Vision, AppKit, and ScreenCaptureKit are macOS APIs. Windows and Linux need separate capture and recognition backends.
