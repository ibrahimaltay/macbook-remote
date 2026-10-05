# Test cases

Common preconditions unless a case says otherwise:
- Bluetooth is on on both devices. They do **not** need to be paired in System Settings.
- LazyRemote is running on the Mac, is **Enabled**, and has Accessibility access.
- LazyRemote on the iPhone has Bluetooth permission.

---

# TC-1 - First pairing (happy path)
**Given**
- The Mac and the iPhone have never been paired in LazyRemote.

**Steps**
1. Open LazyRemote on the iPhone and keep it in the foreground.
2. On the Mac, open the LazyRemote menu bar menu.
3. Under "Waiting for approval", click **Allow iPhone (XXXX)** within 5 minutes.

**Expected**
- While waiting, the iPhone shows "Allow this iPhone on <Mac>".
- After step 3, the iPhone shows the Mac's name with a green dot.
- The Mac menu shows "1 device connected" and lists the iPhone under **Paired Devices**.
- Pressing a d-pad button on the iPhone moves the selection on the Mac.

**Notes**
- The request is only visible inside the menu; the menu bar icon does not change.
- If the iPhone locks or leaves the app before step 3, the request disappears.

---

# TC-2a - Approval request times out
**Given**
- The Mac and the iPhone have never been paired.

**Steps**
1. Open LazyRemote on the iPhone; keep the screen awake.
2. Confirm the Mac menu shows **Allow iPhone (XXXX)**. Do not click it.
3. Wait more than 5 minutes.
4. On the iPhone, tap **••• → Reconnect**.

**Expected**
- After step 3, the iPhone shows "Secure connection timed out. Reconnect and check approval on the Mac."
- After step 3, the request is gone from the Mac menu and the icon shows a warning.
- After step 4, a new request appears with a **different** 4-character code.

---

# TC-2b - Mac removes the iPhone
**Given**
- The Mac and the iPhone are paired and connected.

**Steps**
1. On the Mac, open **Paired Devices → Remove iPhone**.
2. On the iPhone, tap **••• → Reconnect**.
3. On the Mac, click **Allow iPhone (XXXX)**.

**Expected**
- After step 1, the iPhone shows "Access was revoked on the Mac…".
- After step 2, the Mac shows a new approval request.
- After step 3, the connection is established.

---

# TC-2c - iPhone forgets the Mac
**Given**
- The Mac and the iPhone are paired.

**Steps**
1. On the iPhone, tap **••• → Forget Mac** and confirm.

**Expected**
- The iPhone scans, finds the Mac and connects **without** a new approval request on the Mac, because the Mac still trusts this iPhone.

---

# TC-2d - App reinstalled on the iPhone
**Given**
- The Mac and the iPhone are paired.

**Steps**
1. Delete LazyRemote from the iPhone and install it again.
2. Open LazyRemote on the iPhone.

**Expected**
- If iOS kept the app's keychain data: the iPhone reconnects as before.
- If iOS removed it: the Mac shows a new approval request, and clicking Allow connects.

**Current behaviour (bug)**
- If the keychain data was removed, the iPhone shows "Secure connection failed" and the Mac shows **no** request.
- Workaround: on the Mac, **Paired Devices → Remove iPhone**, then reconnect.

---

# TC-3a - Mac's Bluetooth ID changes, iPhone has forgotten the old ID
**Given**
- The Mac and the iPhone are paired.
- The iPhone's saved Mac ID is one iOS no longer recognises.

**Steps**
1. Open LazyRemote on the iPhone.

**Expected**
- The iPhone shows "Looking for your Mac…", finds the Mac under its new ID and connects.
- No approval request appears on the Mac.

**How to reproduce**
- Launch the app with a made-up saved ID (it overrides the stored value for that launch only):
  `xcrun devicectl device process launch --device <udid> com.altay.lazyremote -lastPeripheral 00000000-0000-0000-0000-000000000001`

---

# TC-3b - Mac's Bluetooth ID changes, iPhone still knows the old ID
**Given**
- The Mac and the iPhone are paired.
- The Mac now advertises under a new Bluetooth ID.
- iOS still recognises the old saved ID.

**Steps**
1. Open LazyRemote on the iPhone.
2. Wait 15 seconds.

**Expected**
- The iPhone gives up on the old ID, shows "Looking for your Mac…", finds the Mac under its new ID and connects.
- No approval request appears on the Mac.

**Current behaviour (bug)**
- The iPhone shows "Connecting to LazyRemote…" forever. Connecting to a saved ID has no timeout and never falls back to scanning.
- Workaround: on the iPhone, **••• → Forget Mac**.

**How to reproduce**
1. Copy the iPhone app's settings to the Mac and note `lastPeripheral`:
   `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.altay.lazyremote --source Library/Preferences/com.altay.lazyremote.plist --destination /tmp/lazyremote.plist`
   `plutil -p /tmp/lazyremote.plist`
2. Try to make the Mac change its Bluetooth ID: restart the Mac's Bluetooth service with `sudo pkill bluetoothd`, or restart the Mac.
3. Force-quit and reopen LazyRemote on the iPhone.
4. If it connects, repeat step 1. A different `lastPeripheral` means the ID changed and the app recovered (pass). The same value means the ID did not change, so the case was not exercised.
- macOS does not reliably change its Bluetooth ID on demand, so this case is best covered by an automated test with a fake Bluetooth layer.