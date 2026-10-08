# LazyRemote Secure Protocol v2

Canonical specification of the current implementation, not a claim of independent
security certification or completed hardware validation. The wire formats are
defined by [SecureHandshake](../Sources/RemoteSecurity/SecureHandshake.swift),
[SecureSession](../Sources/RemoteSecurity/SecureSession.swift),
[SecureFrame](../Sources/RemoteProtocol/SecureFrame.swift), and
[SecureMessage](../Sources/RemoteProtocol/SecureMessage.swift). Endpoint policy is
implemented in [RemoteClient](../Sources/RemoteClientCore/RemoteClient.swift) and
[RemoteServer](../Sources/RemoteServerCore/RemoteServer.swift).

## Scope and Threat Model

The iPhone is the BLE central and protocol client; the Mac is the BLE peripheral
and protocol server. Application-level encryption replaces the old plaintext
transport. There is no dependency on OS BLE bonding, no system pairing prompt in
this flow, and no legacy fallback. BLE permissions are ordinary `.writeable`;
security comes from the protocol, not from ATT encryption-required permissions.

First pairing is Allow-only trust on first use (TOFU). The Mac owner approves the
presented identity, and the client pins the Mac after encrypted approval. There
is no independently compared fingerprint, pairing code, or authenticated
out-of-band channel. A device name is self-asserted, not proof of identity.
**First pairing is not MITM-proof:** an active attacker can substitute identities
and establish separate sessions. Signatures prove possession of the identity
keys presented in the handshake, not that an unpinned identity belongs to the
intended device. Later connections reject changes to an existing transport pin.

The handshake uses persistent Ed25519 signing identities, fresh X25519 ephemeral
agreement keys, and fresh 32-byte random values. Ephemeral session forward secrecy
is contingent on no successful MITM and destruction of ephemeral/session secrets;
the Swift code drops references, but does not promise explicit memory zeroization.
Compromised endpoints, malicious approved peers, denial of service, traffic timing,
BLE advertisements, identity public keys, and handshake/frame metadata are outside
the confidentiality guarantee. Approval authorizes key, pointer, and text injection
into whichever application receives the Mac's events.

## BLE Surface

| Item | UUID | Properties |
| --- | --- | --- |
| Service | `CD7662C9-9F43-489F-BDD2-9E82E334D46B` | Advertised by Mac |
| Secure control | `64B1C682-BC10-48CF-93F5-8242F02396DD` | Client write with response; server notify |
| Secure input | `3F728627-E19A-4DF6-84CB-81E06DA0C7E9` | Client write with/without response |

The client subscribes to control notifications before sending ClientHello. The
server allocates peer state on subscription. Reads are unsupported. Writes must
have ATT offset zero. Missing secure characteristics or required properties fail
with an update-required status; old key/control UUID constants and legacy payload
helpers remaining in the package are not published or accepted by these endpoints.

## Handshake Bytes

All labels below are literal UTF-8 bytes, without a NUL terminator or separator.
`+` means byte concatenation. Identities are Ed25519 public keys (32 bytes),
ephemeral public keys are X25519 (32 bytes), and signatures are Ed25519 (64 bytes).
Random fields are 32 bytes. Handshake version is the byte `0x02`.

| Message | Exact bytes | Length |
| --- | --- | --- |
| ClientHello | `[2, 1] + clientIdentity32 + clientEphemeral32 + clientRandom32` | 98 |
| Unsigned ServerHello | `[2, 2] + serverIdentity32 + serverEphemeral32 + serverRandom32` | 98 |
| ServerHello | `unsignedServerHello + serverSignature64` | 162 |
| ClientFinish | `[2, 3] + clientSignature64 + encryptedClientFinish29` | 95 |
| ServerFinish | `encryptedServerFinish29` | 29 |

For each 98-byte hello: version is at offset 0, role byte at 1, identity at 2,
ephemeral key at 34, and random at 66. Hello lengths and role bytes must match
exactly. ServerHello's signature starts at offset 98. ClientFinish's signature
starts at offset 2 and its record at offset 66.

```text
transcript = UTF8("LazyRemote/handshake/v2")
             + clientHello98 + unsignedServerHello98
serverSignature = Ed25519.Sign(serverIdentityPrivate, transcript + UTF8("server"))
clientSignature = Ed25519.Sign(clientIdentityPrivate, transcript + UTF8("client"))
sharedSecret = X25519(localEphemeralPrivate, peerEphemeralPublic)
```

The server checks any client pin before constructing ServerHello. The client
checks any server pin and verifies the server signature before sending
ClientFinish. The server verifies the client signature and opens the encrypted
client confirmation before returning its encrypted confirmation. Each confirmation
is the one-byte SecureMessage `finish` (`0x09`), encrypted at sequence zero in its
respective control lane. ServerFinish uses frame kind encryptedControl, not a
separate handshake kind. A session can be taken only after confirmation, once;
wrong phases or failed validation cannot advance the handshake.

## Key Derivation and Records

Directional lanes have independent keys, nonce prefixes, and sequence state:

| Raw value | Lane | Sender | Receiver |
| --- | --- | --- | --- |
| 1 | clientControl | Client | Server |
| 2 | serverControl | Server | Client |
| 3 | clientInput | Client | Server |

```text
binding = SHA256(transcript)
material = HKDF-SHA256(sharedSecret,
                      salt = binding,
                      info = UTF8("LazyRemote/v2/lane/" + decimal(lane.rawValue)),
                      outputLength = 36)
key = material[0..<32]
noncePrefix = material[32..<36]
```

For example, lane 1's info is exactly `LazyRemote/v2/lane/1`. Records use
AES-256-GCM with a 16-byte authentication tag and this 12-byte header:

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 1 | Version, 2 |
| 1 | 1 | Lane, 1/2/3 |
| 2 | 8 | Sequence, unsigned big-endian |
| 10 | 2 | Sealed length: ciphertext plus tag, unsigned big-endian |
| 12 | Variable | Ciphertext followed by 16-byte tag |

```text
nonce = noncePrefix4 + sequence8BigEndian
authenticatedData = SHA256(transcript) + header12
record = header12 + ciphertext + tag16
```

The nonce is reconstructed, not transmitted separately. Plaintext must be nonempty
and at most 8164 bytes; total record size is 29 through 8192 bytes. The sealed
length must equal the bytes following the header. Lane and sender role must match.
Sequence numbers begin at zero per lane; `UInt64.max` is not usable and exhaustion
fails closed. Control lanes require exact contiguous sequences starting at zero.
Input accepts any first valid sequence, then only strictly increasing sequences,
allowing gaps for lost pointer traffic. Authentication must succeed before the
receive sequence is committed. Old or repeated input sequences are rejected even
if a different frame ID is supplied. Finish consumes control sequence 0; name
uses clientControl sequence 1, and pending/approved starts at serverControl 1.

## BLE Fragmentation

Encrypt the entire application message first, then fragment the resulting record.
Handshake messages are fragmented directly. Each BLE write/notification contains
one frame: a 16-byte header and a nonempty slice of the message.

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 1 | Magic, `0xA7` |
| 1 | 1 | Version, 2 |
| 2 | 1 | Kind |
| 3 | 1 | Flags: 0, or 1 for final fragment |
| 4 | 8 | Message ID, unsigned big-endian |
| 12 | 2 | Total reassembled bytes, unsigned big-endian |
| 14 | 2 | Offset, unsigned big-endian |
| 16 | Variable | Payload |

Kinds are clientHello=1, serverHello=2, clientFinish=3, encryptedControl=4,
encryptedInput=5. Maximum reassembled sizes are 1024 for handshake kinds and 8192
for encrypted kinds. Sender MTU must be at least 20 bytes; payload capacity is
MTU minus 16, so an MTU of 20 carries 4 payload bytes. MTU uses the appropriate
Core Bluetooth maximum write/update length; there is no fixed 20-byte assumption.

An assembler permits one in-progress message, beginning at offset zero. Kind, ID,
and total must remain identical; offsets must be exactly contiguous. The final
flag must be set if and only if the fragment ends at total. Unknown flags/kinds,
empty payloads, overlap, gaps, interleaving, or size violations reset assembly and
fail the endpoint. Partial assembly expires after 10 seconds without progress or
30 seconds total. Endpoints also enforce timers when no further frame arrives.
The server has separate control and input assemblers for each peer; the client
has one notification assembler. Senders serialize frames of each message.

**Frame IDs are transport metadata, not cryptographic identities or authenticated
replay counters.** The frame header is not included in record AEAD. The client
additionally requires increasing completed server frame IDs; the server does not
use inbound IDs as a replay guarantee. Record AEAD, lane direction, and record
sequences provide the cryptographic replay checks. Text IDs correlate receipts,
and pending/trusted UUIDs identify UI/store entries; none replace signing keys.

## Encrypted Application Messages

Each plaintext begins with one tag byte. IDs here are unsigned 64-bit big-endian;
strings occupy the remaining bytes as nonempty valid UTF-8, without a length field.

| Tag | Payload after tag | Plaintext size | Lane |
| --- | --- | --- | --- |
| 1 key | command1 + isDown1 (0 or 1) | 3 | clientInput |
| 2 pointer move | `[1] + dxInt16LE + dyInt16LE` | 6 | clientInput |
| 2 pointer click | `[2] + button1 + count1` | 4 | clientInput |
| 2 pointer scroll | `[4] + dxInt16LE + dyInt16LE + phase1` | 7 | clientInput |
| 3 text | textID8 + UTF-8 (1..4096 bytes) | 10..4105 | clientInput |
| 4 name | UTF-8 (1..128 bytes) | 2..129 | clientControl |
| 5 pending | None | 1 | serverControl |
| 6 approved | None | 1 | serverControl |
| 7 revoked | None | 1 | serverControl |
| 8 textResult | textID8 + success1 (0 or 1) | 10 | serverControl |
| 9 finish | None | 1 | Control confirmation only |

Commands are up=0, down=1, left=2, right=3, mid/Space=4, backspace=5, enter=6. Mac
keycodes are respectively 126, 125, 123, 124, 49, 51, 36. Pointer buttons are left=0, right=1;
count is a raw UInt8 (the codec adds no narrower range restriction). Scroll phases
are began=1, changed=2, ended=3, momentumBegan=4, momentum=5, momentumEnded=6;
scroll deltas are pixels in content direction (positive dy reveals content above).
Pointer sub-tag 3 is unused because legacy `TextChunk` occupied it. Pointer
deltas are signed little-endian, unlike record/frame/text IDs. Unknown tags,
invalid lengths, invalid UTF-8, and invalid command/button/boolean values fail.
Only key, pointer, and text messages are accepted by the approved input decoder.

## Approval, Trust, and Recovery

1. Client subscribes and sends ClientHello; server sends signed ServerHello.
2. Client verifies the pin/signature and sends signed ClientFinish with encrypted
   confirmation; server verifies both and sends encrypted ServerFinish.
3. Client verifies ServerFinish and sends its encrypted device name. Only now may
   the Mac expose a pending approval entry. A hello alone cannot request Allow.
4. A known signing key not blocked in memory is approved after its saved name and
   transport association update succeeds. Otherwise the server sends pending and
   the owner must select Allow within 300 seconds.
5. Allow persists trust before sending approved. The client persists the Mac's pin
   after receiving authenticated approved, and only then reports connected. Input
   is forbidden before server approval and client readiness.

[PeerTrustStore](../Sources/RemoteSecurity/PeerTrustStore.swift) stores the 32-byte
identity private key in `identity-v2` and JSON trusted peers in `peers-v2`, in
non-synchronizing Keychain generic-password items. Services are
`com.altay.lazyremote.client.security` and `com.altay.lazyremote.server.security`.
iOS saves use `WhenUnlockedThisDeviceOnly`; macOS does not explicitly set an
accessibility class. Each trusted entry contains a UUID, 32-byte public key,
name, and optional Core Bluetooth transport UUID. Duplicate IDs, keys, transport
IDs, malformed names, and malformed stored data are rejected. Transport UUIDs
help locate pins; authentication is by signing-key possession, not BLE identifiers.

Old UserDefaults approvals are ignored: users must reapprove under the new
Keychain trust scheme. UserDefaults `lastPeripheral` remains a reconnect hint,
not an authorization credential. Missing identity with saved peers, malformed
identity/trust data, Keychain errors, or changed pins fail closed. An identity is
generated only when absent and the peer list is empty; it is saved before use.
Loss of both identity and peer records cannot be distinguished from a fresh install.
There is no silent pin replacement or plaintext downgrade.

The iOS ellipsis menu offers Reconnect (stop/start while retaining trust) and
Forget Mac with confirmation. Forget removes only the selected Mac's trust and
saved transport hint, retaining the phone's identity. A persistence failure leaves
the client stopped and visibly failed; retry Forget Mac before reconnecting.
After successful forgetting, the next connection is TOFU again: verify the Mac
before discarding a changed pin.

Mac Paired Devices offers Remove. Removal immediately denies the UUID/key in
memory, disables affected sessions, releases held keys, and attempts encrypted
revoked notification before dropping the peer. If Keychain removal fails, the
status visibly reports failure and the saved entry remains available for retry
Remove (the core error calls this Forget). **Persistence is not guaranteed until
that retry succeeds.** The block is for the current server instance/run, not a
durable revocation across process restart. Do not assume restarting fixes trust
errors or preserves an unsuccessful revocation. Explicit successful reapproval
can clear a block. Failure to deliver revoked does not restore input access.

The Mac also offers Forget All Devices with a destructive confirmation, including
when Disabled or no devices can be listed. Cancellation does not change trust or
sessions. Confirmation immediately closes every approved, pending, and handshaking
peer to input, releases held keys, resets partial messages, and attempts encrypted
revoked notifications before dropping peers. The listener remains enabled if it
was enabled; this is session revocation, not guaranteed physical BLE disconnection.

Bulk reset deletes only the `peers-v2` Keychain item in one operation, retaining
the Mac's `identity-v2` and app preferences. With a valid existing identity, this
explicit reset can remove malformed peer records without decoding them. A missing
identity with a saved peer record, corrupt identity, or Keychain error still fails
closed; reset never creates or replaces the identity. Repeated resets are safe,
including on a fresh store with neither record.

If bulk deletion fails, both automatic and explicit approval remain blocked for
the current server instance, including across Enabled toggles and sleep/wake.
The menu retains a separate Pairing Reset Failed action for error details and
retry instructions even if Bluetooth status changes. Only a successful bulk-reset
retry removes this block. Saved records are not shown as usable approvals while
blocked. **An unsuccessful reset is not durable across app restart**: old saved
approvals may return, so retry Forget All Devices before restarting.

After successful reset, phones use Reconnect and the Mac owner selects Allow
again. The retained Mac identity still matches existing phone pins; Forget Mac
is not required for an ordinary Mac-side reset. This does not erase phone-side
trust, rotate signing identities, or manage OS Bluetooth bonds, and introduces
no new wire message or plaintext fallback.

## Delivery, Limits, and Lifecycle

Keys, clicks, text, and client control/handshake frames use `.withResponse` with
one outstanding write, checked callbacks, and serialized record frames. This
provides reliable ATT transport, not proof of foreground event delivery. Pointer
movement is coalesced, fractional deltas retained, and pending axes clamped to
-32768..32767; move frames use `.withoutResponse` and resume on Core Bluetooth
readiness. Moves share the serialized input queue with reliable events, so frames
of different input records are not interleaved. Scroll `changed` and `momentum`
deltas are coalesced and sent the same way as moves; the other scroll phases flush
pending scroll deltas and are sent with response so a phase transition is never lost.
No unreliable fallback is used
for keys or clicks. Server notifications resume when updateValue backpressure clears.

Unicode text is capped at 4096 UTF-8 bytes, encoded and encrypted as one message,
then fragmented; legacy TextChunk is not the secure transport. Only one text
request may be outstanding per client, with a 30-second receipt deadline. The UI
trims leading/trailing whitespace before sending. The server invokes
`KeyInjector.type(value)` and then sends encrypted `textResult(success: true)`.
That receipt means **type was invoked, not that the foreground app received or
accepted the text**: CGEvent creation/posting and Accessibility delivery have no
application acknowledgement. Injection uses Unicode event strings in character-
boundary chunks and real Return presses for newlines, independent of key layout.
Do not automatically retry text after timeout/disconnect: injection may already
have happened while its receipt was lost, and retry can duplicate it. Current
endpoints do not resend pending text or provide durable text-ID deduplication.

| Limit/deadline | Current endpoint behavior |
| --- | --- |
| Client outgoing queue | At most 2048 frames and 65536 framed bytes |
| Client queued job / active record | 30 seconds each |
| Client setup/handshake stages | 10-second stage timers, refreshed on handshake progress |
| Client approval wait | 300 seconds; refreshed on pending |
| Server peer count | At most 8 subscribed peers, each with independent session/queues |
| Server notifications per peer | At most 2048 frames and 16384 framed bytes |
| Server notification stall | 10 seconds without progress |
| Server handshake through name | 10 seconds idle or 30 seconds from subscription |
| Server pending approval | 300 seconds |
| Partial frame assembly | 10 seconds idle or 30 seconds total |

Server expiry checks run once per second; these are not exact wall-clock delivery
guarantees. Queue overflow, timeout, authentication/phase errors, and malformed
traffic fail the connection/peer rather than bypassing protection. The server
drops protocol state; it does not claim to forcibly terminate the physical BLE
link. Notifications target the specific subscribed central. Multiple approved
phones can inject concurrently; this is not exclusive foreground ownership. Held
commands are tracked per peer, and a release is posted only when no other approved
peer still holds that command. Held keys are released on peer failure/removal,
unsubscribe, server stop, or Bluetooth state loss.

Client failures clear session, assemblies, queued events, pending motion, and text
receipt state, cancel the connection, and remain failed until explicit recovery.
Ordinary disconnect while running reconnects to the same peripheral and performs
a fresh handshake; no session is resumed. A saved peripheral can be retrieved
without scanning. Core Bluetooth connect itself has no application timeout here;
setup timers start after didConnect. Radio/authorization changes clear volatile
state. The Mac UI rebuilds the listener on wake when enabled. Server stop/state
loss clears peers; persistent trust survives, but process restart loses transient
denial sets. The phone manages one active Mac at a time. Neither stable transport
identifiers across restarts nor automatic recovery from pin/key loss is assumed.

## Outstanding Release Gates

Package tests and simulator/build checks do not establish physical BLE behavior.
Before release, validate on real iPhone/Mac hardware: packet inspection for absence
of plaintext input/name/control, MTU fragmentation, sustained pointer and text
backpressure, write/notification failures, radio loss, sleep/wake, multiple peers,
approval/removal persistence failures, and pin-change/update/Forget Mac recovery.
Obtain independent protocol/security review. Complete signing/notarization and
App Store preparation, and review encryption export classification/compliance.
Do not treat earlier plaintext hardware tests as secure-v2 validation or change
the iOS export declaration automatically without that review.