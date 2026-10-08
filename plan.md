# LazyRemote - Current Status and Release Plan

## Product

An iPhone remote for a Mac over BLE, with D-pad, trackpad, and Unicode text pages.
No Wi-Fi, router, Bonjour, or Local Network permission is required. The iPhone is
the central; the Mac is the peripheral. The Mac menu bar app injects CGEvent keys,
pointer events, and text into the receiving foreground application without taking
focus, and offers Enable, Launch at Login, Allow, and Remove controls.

## Implemented Security and Transport

The current transport is application-encrypted secure protocol v2. The canonical
byte layouts, state machine, limits, and threat model are in
[docs/secure-protocol.md](docs/secure-protocol.md).

- Persistent Ed25519 identities and trusted peer public keys live in Keychain.
  Fresh X25519 agreement, signed transcripts, HKDF-SHA256 lane keys, AES-256-GCM
  records, directional sequences, and bounded BLE fragmentation protect sessions.
- The Mac exposes approval only after the client signature, encrypted finish, and
  encrypted name are verified. Input is accepted only from approved sessions.
  Returning peers authenticate by signing key, not by BLE transport UUID alone.
- First pairing is Allow-only TOFU, explicitly not MITM-proof. There is no
  independent fingerprint/code comparison, OS BLE-bond dependency, system pairing
  prompt, or plaintext/legacy fallback. Forward secrecy depends on no successful
  MITM and destruction of ephemeral/session secrets.
- Old UserDefaults approvals are ignored; users must reapprove with Keychain trust.
  Changed pins, detected identity loss, malformed trust, and Keychain errors fail
  closed. Never discard a changed pin without verifying the intended Mac.
- Mac Remove blocks affected identities in memory immediately and releases held
  keys. If persistence fails, a visible error and saved entry permit retry Remove;
  durable revocation is not guaranteed until successful, including across restart.
- The iOS ellipsis menu offers Reconnect and confirmed Forget Mac. Reconnect keeps
  trust; Forget removes the selected Mac's pin/hint, not the phone's identity. A
  failed Forget leaves the client stopped until retry succeeds.
- Keys and clicks now use reliable writes with response. Pointer moves are
  coalesced and use writes without response; all record frames are serialized.
  Control writes are reliable and server notifications respect backpressure.
- Text is at most 4096 UTF-8 bytes, encrypted whole before fragmentation. Its
  encrypted receipt confirms `KeyInjector.type` was invoked, not foreground
  delivery. Never automatically retry text after ambiguous timeout/disconnect.

## Connection and Permissions

The phone remembers a peripheral identifier as a reconnect hint, not a credential.
Ordinary disconnect reconnects while running with a new handshake; failed secure
connections need explicit recovery. Queues, assemblies, motion, and pending text
are cleared rather than resumed. Core Bluetooth connect has no application timeout;
post-connect discovery/handshake and approval stages have bounded timers. The Mac
rebuilds its listener on wake when enabled. Up to eight subscribed phones have
independent server state; held-key cleanup respects other approved peers' holds.
The phone connects to one Mac at a time. Do not assume transport IDs remain stable
across restart or that restart resolves trust/persistence errors.

Both apps require Bluetooth permission. macOS also requires Accessibility access
and a signed app with a stable bundle identifier for dependable CGEvent delivery.
Use the app bundle, not a bare SPM executable, for injection testing. The Mac app
is not sandboxed. The iPhone keeps its screen awake while connected.

## Project and Builds

- [Package.swift](Package.swift): shared package and test targets.
- `Sources/RemoteProtocol/`: message codecs, secure records' outer frames, BLE UUIDs.
- `Sources/RemoteSecurity/`: handshake, session encryption, Keychain trust.
- `Sources/RemoteClientCore/`: central, client state, serialized writes and receipts.
- `Sources/RemoteServerCore/`: peripheral, approval, input decoder and CGEvent injection.
- `Sources/remotectl/`: CLI test harness; `--allow-new` is for testing only.
- `iOSApp/` and `macApp/`: SwiftUI applications with an existing Xcode project, split into
  `Models/` (app-local only), `Views/` and `ViewModels/`; the `@main` entry stays at the root.
- [project.yml](project.yml) and [MacRemote.xcodeproj/project.pbxproj](MacRemote.xcodeproj/project.pbxproj):
  XcodeGen configuration and generated project; Xcode/iOS SDK are available.
- [scripts/make-app.sh](scripts/make-app.sh): signed-bundle CLI injection harness.
- `Tests/`: protocol, security, secure transport, and approved-input decoding tests.

```sh
swift build
swift test
# Regenerate after changing project.yml:
xcodegen generate
xcodebuild -project MacRemote.xcodeproj -scheme MacRemote \
  -configuration Debug -derivedDataPath .build/dd build
xcodebuild -project MacRemote.xcodeproj -scheme RemoteDPad \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd build
```

Builds/unit tests are not substitutes for physical secure-v2 BLE testing. Earlier
plaintext iPhone/Mac end-to-end verification does not establish the new transport.

## Distribution and Outstanding Gates

The intended distribution is a free Mac app shared through GitHub/website and a
free iPhone app on the App Store. App Store distribution is a goal, not out of scope
or already completed. Developer ID signing, hardened runtime, and notarization for
Mac distribution still need release validation.

The website is static HTML/CSS in `site/`, deployed to GitHub Pages by
`.github/workflows/pages.yml` (https://ibrahimaltay.github.io/macbook-remote/). It
hosts the App Store Privacy and Support URLs. Its download button points to
`releases/latest/download/LazyRemote.dmg`, so every release must attach the
unversioned `LazyRemote.dmg` that `scripts/release-mac.sh` produces. Keep
`site/privacy.html` in sync with `PRIVACY.md`.

- Physical secure-v2 iPhone/Mac tests, including packet inspection for plaintext
  leakage, MTU fragmentation, sustained backpressure, failures, sleep/wake,
  reconnection, multiple peers, held-key cleanup, and receipt ambiguity.
- Pin-change/update/re-pairing flows and Keychain key-loss/approval/removal failure
  tests on hardware, including unsuccessful revocation across restart.
- Independent protocol/security review before treating this custom handshake as
  release-ready.
- Signing/notarization and App Store review preparation, privacy disclosures, and
  encryption export classification/compliance review. Do not automatically change
  the iOS export flag before that review.

Media/system-volume keys, custom key mapping, and simultaneous control of multiple
Macs from one phone remain out of scope. No release gate above is marked complete.
