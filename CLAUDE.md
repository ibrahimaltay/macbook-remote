# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

LazyRemote: an iPhone app that remote-controls a Mac over Bluetooth LE (D-pad/media keys, trackpad, Unicode text). The iPhone is the BLE central; the Mac menu-bar app is the peripheral and injects CGEvents. No Wi-Fi/Bonjour. `plan.md` has current status and release plan; `docs/secure-protocol.md` has the canonical wire formats, state machine, and threat model.

## Layout

- `Sources/` — SwiftPM library targets shared by both apps (all logic worth testing lives here):
  - `RemoteProtocol`: BLE service/characteristic UUIDs, `Command`, `PointerEvent`, `TextChunk`, `SecureFrame`/`SecureMessage` wire encodings. No dependencies.
  - `RemoteSecurity`: app-layer encryption (Ed25519 identities, X25519 + HKDF, AES-256-GCM, signed-transcript handshake in `SecureHandshake`, `SecureSession`, Keychain-backed `PeerTrustStore`).
  - `RemoteClientCore` (iOS side `RemoteClient`) and `RemoteServerCore` (Mac side `RemoteServer`, `KeyInjector`, `PointerInjector`, `PairedDeviceStore`) — CoreBluetooth central/peripheral plus input handling.
  - `remotectl`: CLI test harness for the Mac side (`keytest`, `serve`, `send`) without the phone.
- `iOSApp/` (target `RemoteDPad`, bundle `com.altay.lazyremote`) and `macApp/` (target `MacRemote`, product `LazyRemote`) — thin SwiftUI shells (Views / ViewModels) over the library products.
- `project.yml` is the XcodeGen source of truth; `MacRemote.xcodeproj` is generated from it (run `xcodegen generate` after editing `project.yml` or adding/removing app files). Version numbers live there.

## Commands

```sh
swift build
swift test                                   # all package tests
swift test --filter RemoteSecurityTests      # one test target
swift test --filter SecureHandshakeTests/testName   # one test

xcodegen generate
xcodebuild -project MacRemote.xcodeproj -scheme MacRemote -configuration Debug -derivedDataPath .build/dd -quiet build
"./Start Mac Remote.command"                 # builds (if needed) and launches the Mac app
scripts/make-app.sh                          # wrap remotectl in a signed .app (needed so Accessibility/key posting works)
scripts/release-mac.sh                       # Developer ID signed, notarized DMG in .build/release/ (needs notarytool profile)
```

## Things to know

- Package platforms are macOS 13 / iOS 17 but the apps target macOS 14 / iOS 17; Swift 6 strict concurrency is on (e.g. `CBUUID` is non-Sendable, so UUIDs are computed properties).
- Security is deliberately fail-closed: changed pins, Keychain errors, and malformed trust refuse the connection. Pairing is Allow-only TOFU on the Mac, with no plaintext/legacy fallback. Don't add fallbacks or auto-discard pins; read `docs/secure-protocol.md` before touching handshake or framing code, and keep `Tests/` in step with byte-layout changes.
- Key injection requires Accessibility permission and a stable code identity; an ad-hoc binary with a hash-derived identifier can't post key events (hence `make-app.sh`).
- Trackpad feel (cursor gain, scroll speed/direction, momentum) is tuned in `Sources/RemoteClientCore/Resources/TrackpadTuning.json`, bundled into the iOS app; `swift test` validates it. The phone computes scroll momentum and tags it with phases; the Mac's `PointerInjector` only posts continuous scroll events.
- Mac app is non-sandboxed with hardened runtime; it is a `LSUIElement` menu-bar app.
