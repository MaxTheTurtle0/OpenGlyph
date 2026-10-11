# Build and install OpenGlyph

OpenGlyph runs on macOS 14 or later, on Apple Silicon and Intel Macs. It uses AppKit, Apple Vision, and ScreenCaptureKit. Building requires Swift 5.9 or later and the Xcode command line tools. There are no third-party dependencies.

Install Apple's tools if needed:

```sh
xcode-select --install
```

From the repository root:

```sh
swift test
./scripts/build-app.sh
./scripts/install.sh --skip-build
```

The build produces `build/OpenGlyph.app`. The installer verifies the app's signature, asks the installed OpenGlyph instance to quit, installs into `~/Applications/OpenGlyph.app`, registers its file and URL handlers, and opens it. OpenGlyph appears in the menu bar. Over SSH, if macOS hides the GUI instance from `NSRunningApplication`, the installer verifies the process's executable path, owner, and start time before sending SIGTERM. It refuses replacement if the installed app remains running after ten seconds.

Version 0.1.1 passes the test suite with both the default SwiftBuild runner and `swift test --build-system native` on the tested Swift 6.4 / Xcode 27 toolchain. The native option is deprecated in Swift 6.4. See [verification notes](VERIFICATION.md) for the recognition failure reproduced on that Mac and the recovery behavior.

Use `./scripts/install.sh` to build and install in one command. `--no-open` installs without launching. Set `INSTALL_DIR` to install into another directory you can write to, such as `/Applications` if your account already has permission. No script uses `sudo` or changes macOS privacy settings.

## Screen recording permission

Screen recognition needs macOS Screen Recording permission. In OpenGlyph's onboarding, grant the permission and enable OpenGlyph in System Settings, Privacy & Security, Screen Recording. Some macOS versions call this section Screen & System Audio Recording. Quit and reopen OpenGlyph if macOS requests a restart. The app captures the area you select, performs recognition locally, and discards the image. It does not record audio.

Keep the installed bundle at the same path. The bundle identifier is `app.openglyph.mac`; local ad-hoc builds also use a stable designated signing requirement. macOS may still ask for permission again after an OS update, a signing-identity change, or installation at another path.

The app does not require Accessibility permission for its global shortcut. macOS mediates clipboard access and the files you open through its regular APIs.

The CLI's `--diagnostics` permission check applies to the calling process. When launched over SSH, macOS can give it a different permission context from the running GUI app. Use the app's permission indicator when checking screen access in your desktop session.

## Universal and development builds

```sh
./scripts/build-app.sh --universal
./scripts/build-app.sh --debug
```

The default release build targets the current Mac's architecture. `--universal` creates one bundle with `arm64` and `x86_64` executables. The app's minimum deployment target is macOS 14. Use `APP_VERSION=0.2.0` and `APP_BUILD_NUMBER=2` to set bundle metadata. Versions must have three numeric components.

The app registers these commands:

```sh
open 'openglyph://capture'
open 'openglyph://clipboard'
open 'openglyph://settings'
open 'openglyph://onboarding'
open 'openglyph://history'
```

After installation, Finder's Open With menu can send PNG, JPEG, TIFF, HEIC, HEIF, and PDF files to OpenGlyph.

## App icon

The original blue reading-frame icon is drawn in `scripts/draw-icon.swift` using AppKit. It includes no third-party artwork or embedded font. Regenerate its PNG preview and ICNS file with:

```sh
./scripts/generate-icon.sh
```

The build regenerates the icon when its drawing source changes. The generated artwork is covered by this repository's MIT license.

## Distribution and signing

```sh
./scripts/package.sh --universal
./scripts/package.sh --skip-build --dmg
```

Archives and SHA-256 checksums appear in `build/dist/`. ZIP files preserve the app bundle; optional DMG files include a shortcut to Applications. Verify a downloaded archive with `shasum -a 256 -c OpenGlyph-VERSION-macos-ARCH.zip.sha256` in the archive's directory.

The build automatically uses an installed Developer ID Application identity when one is available. It never exports a certificate or private key. Set `CODE_SIGN_IDENTITY` to a particular identity name or fingerprint to select it. Set `CODE_SIGN_IDENTITY=-` to force ad-hoc signing.

Ad-hoc signing verifies local bundle integrity. It does not provide Apple's notarization or identify the publisher. Builds downloaded from GitHub may need a deliberate approval through System Settings, Privacy & Security, after the first attempt to open them. Building from source avoids the downloaded application's quarantine. The scripts do not remove quarantine or disable Gatekeeper.

For a public notarized release, use your own Apple Developer ID identity, build and package, then submit the archive using a credential profile you have already stored in your keychain:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh --universal
./scripts/package.sh --skip-build
xcrun notarytool submit build/dist/OpenGlyph-VERSION-macos-universal.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple build/OpenGlyph.app
./scripts/package.sh --skip-build --dmg
```

If you distribute a DMG, submit and staple the final DMG too. Apple documents [notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

GitHub Actions runs the tests, builds a universal app, and stores the ZIP and checksum as workflow artifacts. Pushing a `vX.Y.Z` tag publishes those files as GitHub release assets using the workflow's repository token. CI builds use ad-hoc signing and require no Apple credentials.

## Platform scope

Linux and Windows are not supported yet. The capture, shortcut, app UI, and recognition backends use Apple's APIs. The history format and app behavior can be shared by a future port, but those platforms need their own implementations and verification.
