# iPhone → Mac Remote (D-pad) — Plan

## Goal
An iPhone app with 5 buttons that controls a MacBook.
Each tap sends an arrow key (or Space) to the Mac.

Main use: controlling video playback from the couch.
This is done with a Bluetooth keyboard today, so the same keys work.

## Components

### 1. iPhone app (client)
- SwiftUI, 5 buttons in a plus shape:
  ```
        [Top]
  [Left] [Mid] [Right]
       [Bottom]
  ```
- Finds the Mac by scanning for its BLE service (`CBCentralManager`).
- Connects and writes key events to a characteristic.
- Shows connection status (connecting / waiting for approval / connected).
- Remembers the Mac's peripheral identifier, so later launches skip scanning.
- Haptic feedback on each press, so it works without looking at the screen.
- Keeps the screen awake while connected (`isIdleTimerDisabled = true`), or iOS locks
  the phone and drops the connection.

### 2. Mac app (server)
- Menu bar app. Starts at login.
- Advertises a BLE service with `CBPeripheralManager`. No Wi-Fi and no router involved.
- Receives messages and presses keys with `CGEvent`.
- Runs as `.accessory` (`LSUIElement`) so it never takes focus. The keys have to reach
  the video app, not this one.
- Shows a list of paired devices, with a "remove" option.

## Messages
Two bytes per write to the key-event characteristic: `[command, isDown]`.
ATT delivers each write whole, so there is no framing to do.

| Command | Byte | Mac key     | Key code |
|---------|------|-------------|----------|
| UP      | 0    | Up Arrow    | 126      |
| DOWN    | 1    | Down Arrow  | 125      |
| LEFT    | 2    | Left Arrow  | 123      |
| RIGHT   | 3    | Right Arrow | 124      |
| MID     | 4    | Space       | 49       |

`isDown` is 1 for press, 0 for release. A tap sends both.
This costs almost nothing now and gives press-and-hold for free later:
the Mac repeats the key while it is held.

On the Mac:
- Post with `CGEvent.post(tap: .cghidEventTap)`.
- Set `flags = .maskNumericPad` on arrow keys. Some apps ignore them otherwise.
- Write without response. Waiting for an ACK on every press adds a round trip for
  nothing. Fall back to a write with response only when the queue is full, so a
  press is never silently dropped.

## Security
**The link is not encrypted, and that is not a choice.** macOS does not bond in the
peripheral role for a third-party app. With `EncryptionRequired` permissions set, the
iPhone's reads and writes come back `Encryption is insufficient` /
`Authentication is insufficient`, no pairing prompt ever appears, and nothing works.
Notifications still flow, which makes it look connected while every write fails.
So the characteristics are plain `readable` / `writeable`.

What actually gates access:
1. **Range.** BLE reaches about 10 m, so an attacker has to be in the room.
2. **Approval.** The Mac keeps its own allowlist. A new device connects, writes its
   name, and sits in the menu bar as "waiting" while every key event it sends is
   dropped. Nothing reaches `CGEvent` until the user clicks Allow.
3. **Removal.** Deleting it from the menu sends it back to waiting.

What this does *not* protect against, stated plainly:
- Traffic is plaintext. It is five arrow keys, so there is little to read, but it is
  readable by anyone in range.
- The allowlist keys on `CBCentral.identifier`. Without bonding there is no IRK, so a
  determined attacker in range could try to impersonate an approved device.

If that is not good enough, the two real options are to flip the roles (iPhone as
peripheral, which *can* bond, at the cost of iOS background advertising limits), or to
authenticate the messages ourselves with a shared secret agreed at approval time.

## Reconnection
- Mac advertises the whole time it is running.
- The phone saves the Mac's peripheral identifier and reconnects straight to it,
  skipping discovery.
- `connect(peripheral)` has no timeout. Core Bluetooth keeps the request pending and
  completes it whenever the Mac is back in range, which is why there is no retry loop,
  no backoff, and no path monitor.
- On disconnect, re-issue the connect request and wait.

## Flow
```
First time:
iPhone scans → connects → system pairing prompt → "Allow" in the Mac's menu bar

Every time after:
iPhone reconnects to the saved Mac → ready
Tap button → send UP down, UP up → Mac presses Up Arrow
```

## Permissions
- **Mac:** Accessibility (System Settings → Privacy & Security → Accessibility), needed for `CGEvent`.
  The key press code must live in a signed `.app` bundle. A bare SPM executable is
  ad-hoc signed with a hash-derived identifier, and macOS silently refuses to deliver
  its synthetic events: they show up in an event tap but never reach any app, and
  `AXIsProcessTrusted()` still returns true because it resolves to the parent process.
  `scripts/make-app.sh` wraps the CLI in a bundle with a fixed identifier for testing.
  The grant survives rebuilds as long as that identifier does not change.
- **iPhone:** Bluetooth. Add `NSBluetoothAlwaysUsageDescription` to Info.plist.
  No Local Network key, no Bonjour list, no camera.
- **Mac:** Bluetooth, same key, granted on first use under System Settings →
  Privacy & Security → Bluetooth. No sandbox.

## Out of scope (for now)
- Media keys and system volume. Arrow keys only, same as the Bluetooth keyboard.
  Note this means the keys only reach whichever app is in front.
- Custom key mapping.
- App Store distribution.
- Multiple Macs at the same time.

## Project layout
```
Package.swift            SPM package, builds everything below on the Mac
Sources/
  RemoteProtocol/        Command enum + the 2-byte wire format. Both sides use it.
  RemoteClientCore/      BLE central: scanning, connection, key writes. The iPhone app
                         is a thin SwiftUI layer on this.
  RemoteServerCore/      BLE peripheral + CGEvent injection + the device allowlist.
                         macOS only.
  remotectl/             CLI test harness: keytest, serve, send.
iOSApp/                  SwiftUI sources, waiting for an Xcode project.
macApp/                  SwiftUI menu bar app wrapping RemoteServerCore.
scripts/make-app.sh      Wraps remotectl in a .app bundle so it may post key events.
```

Run the server from the bundle, not from `.build/debug/remotectl`, or key presses
are silently dropped:

```
./scripts/make-app.sh
./.build/MacRemote.app/Contents/MacOS/MacRemote serve --allow-new
```

`--allow-new` approves whatever connects, which is only for testing. The real menu
bar app asks instead.

## Build order
1. ✅ Mac: `CGEvent` key press test (hardcoded). `remotectl keytest`
2. ✅ Mac: BLE advertise + key injection. `remotectl serve`
3. ✅ iPhone: D-pad UI + `CBCentralManager`, send messages. Verified end to end on an
   iPhone 15 against the menu bar app.
4. ✅ Add the 2-byte framing with press/release.
5. ✅ Add reconnection logic + status UI.
6. ❌ Encrypted link. Not possible with macOS as the peripheral — see Security.
7. ✅ Device allowlist on the Mac, replacing the long-term key in the Keychain.
8. ✅ Mac: menu bar UI + launch at login, including the paired devices list.
9. ⬜ Optional: repeat the key on the Mac while a button is held.

## Notes
- The Mac sleeping tears down the peripheral. The menu bar app rebuilds it on
  `NSWorkspace.didWakeNotification`.
- On a free developer account the iPhone build expires every 7 days.
