# LazyRemote

Use your iPhone as a remote for your Mac, over Bluetooth.

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-black)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

**[Website](https://ibrahimaltay.github.io/macbook-remote/)** · **[Download for Mac](https://github.com/ibrahimaltay/macbook-remote/releases/latest)** · iPhone app coming soon to the App Store

## See It in Action

### Trackpad

Move your Mac's cursor and click from your iPhone.

![Using the iPhone trackpad to control the Mac cursor](readme-gifs/trackpad.gif)

### Arrow Keys

Navigate on your Mac with the iPhone's arrow controls.

![Controlling the Mac with the iPhone arrow keys](readme-gifs/arrow-keys.gif)

### Play / Pause

Pause and resume playback without reaching for your Mac.

![Pausing and resuming Mac playback from the iPhone](readme-gifs/play-pause.gif)

### Keyboard

Type on your iPhone and send the text straight to your Mac.

![Sending text from the iPhone keyboard to the Mac](readme-gifs/keyboard.gif)

## Features

- **Arrow keys & play/pause:** control videos and presentations without leaving your seat.
- **Trackpad:** move the cursor; tap to click, two-finger double-tap to right-click.
- **Keyboard:** type on your iPhone and send the text straight to your Mac.
- **Direct and encrypted:** connects over Bluetooth, with no Wi-Fi setup or accounts.
- **Free:** no ads, no tracking, no in-app purchases.

## Installation

### iPhone

The iPhone app will be on the App Store soon.

### Mac

1. Download `LazyRemote.dmg` from the [latest release](https://github.com/ibrahimaltay/macbook-remote/releases/latest).
2. Open `LazyRemote.dmg`.
3. Drag **LazyRemote** into the **Applications** folder.

## Quickstart

1. On your Mac, open **LazyRemote**.
2. When macOS asks for Bluetooth access, select **Allow**.
3. Make sure that the LazyRemote icon comes into view in the menu bar.
4. Click the LazyRemote icon.
5. Select **Open Accessibility Settings…**.
6. Set **LazyRemote** to on.

   **Note:** LazyRemote must have Accessibility access to send key presses and clicks to your Mac.

7. On your iPhone, open **LazyRemote**.
8. When iOS asks for Bluetooth access, select **Allow**.
9. On your Mac, click the LazyRemote icon in the menu bar.
10. Select **Allow** followed by the name of your iPhone.
11. Make sure that the iPhone shows the name of your Mac with a green dot.
12. Use the trackpad and the buttons below it to control your Mac. To type, tap **Type to send** and then select the send button.

## Reset Pairing

To remove every phone's access and pair again:

1. On the Mac, open the LazyRemote menu and select **Forget All Devices…**.
2. Confirm **Forget All Devices**. Connected phones lose access and all saved phone approvals are removed.
3. On each iPhone, select **Reconnect** from the ellipsis menu.
4. On the Mac, select **Allow** for each phone you want to pair again.

The reset works even when **Enabled** is off. It preserves the Mac's identity,
Enabled setting, Launch at Login preference, and Accessibility permission.
Turn Enabled back on before reconnecting if it was off. The iPhone normally
does not need **Forget Mac**, because the Mac's identity has not changed.
This resets LazyRemote approvals, not system Bluetooth bonds.

If the menu shows **Pairing Reset Failed…**, open it for details and retry
**Forget All Devices…**. Access stays blocked for the current app run until the
reset succeeds. Do not assume restarting clears approvals: a failed deletion
can leave them saved.


## License

MIT — see [LICENSE](LICENSE).
