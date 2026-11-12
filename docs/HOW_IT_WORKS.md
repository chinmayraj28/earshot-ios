# How Earshot works

This document explains what happens between two phones, what the platform allows, and
what Earshot does and does not protect against. It is written to be checked against the
code in `EarshotKit/Sources/EarshotKit`.

## The radio layer and its limits

On a real iPhone Earshot uses **Bluetooth Low Energy** through Apple's Core Bluetooth
framework (`BluetoothTransport.swift`). It was chosen for one reason: it is the only
phone-to-phone radio that iOS lets an app keep using while the app is in the background.

| Question | Answer |
| --- | --- |
| Does it need internet, Wi‑Fi, a router or mobile signal? | No. Only Bluetooth must be on. It can be on in Airplane Mode. |
| How far does it reach? | Bluetooth range: the same room, or a few tens of metres with a clear line of sight. Walls, bodies and crowds shorten it. Earshot does not promise a distance. |
| Are messages relayed through other phones? | No. Earshot is direct, phone to phone. It is not a mesh network. |
| What permissions does iOS ask for? | Bluetooth, when Earshot is first switched on. Notifications, later and optionally, when there is a first contact to be notified about. Nothing else. |
| How fast is it? | Slow by internet standards but enough for text and small photos. Expect a short message to arrive almost at once on an open link and a 2,000-character message to take a few seconds. Expect very roughly 5–50 KB/s depending on the phones and the direction, so a photo (about 50–150 KB once Earshot has shrunk it) takes a few seconds to about half a minute. None of these speeds has been measured between two phones yet; they are expectations. |

### Background delivery: what works and what does not

Earshot declares the `bluetooth-central` and `bluetooth-peripheral` background modes.
The rules below are iOS rules, not Earshot choices.

> **Verification status.** On real iPhones we have confirmed discovery, connecting,
> messaging in both directions, and a message reaching a **locked** phone over an open
> link with a notification. The other rows describe how the code is built to behave under
> Apple's documented Core Bluetooth background rules and are expected, not measured. The
> README lists exactly what is still unchecked.

| Situation | What happens |
| --- | --- |
| You opened Earshot earlier, then locked the phone or switched apps. A contact nearby opens Earshot and writes to you. | **Works.** Their phone finds yours, iOS wakes Earshot for a few seconds, the message is decrypted, stored and confirmed, and you get a notification. This can take longer than in the foreground: usually seconds, sometimes up to a minute or so. |
| Two phones are already linked and both apps go to the background while the phones stay in range. | The Bluetooth link stays up. Either person can open Earshot and send straight away. |
| Both phones are locked, with Earshot in the background, when they first come near each other. | **They do not find each other.** A backgrounded iPhone app is only discoverable by a phone that is actively looking for it, and iOS scans very little with the screen off. They link up as soon as either person opens Earshot. |
| You swiped Earshot away in the app switcher. | **Nothing runs** until you open Earshot again. iOS treats a swipe as "stop this app". |
| The phone was restarted. | Nothing runs until you unlock the phone and open Earshot once. |
| iOS removed Earshot from memory by itself (to free memory). | iOS relaunches it in the background when a nearby phone connects (Core Bluetooth state restoration). The link is set up again from scratch. |
| Bluetooth is off, or Bluetooth access was refused. | Earshot cannot work and says so. It starts by itself when that is fixed. |

Notifications are **local notifications** created on the phone when a message arrives.
There is no push service and no server. By default a notification shows only who wrote;
showing the message text is an opt-in setting.

What happens to a message when the other person is not reachable: it is stored on the
sender's phone with the status **Waiting** and is sent automatically the next time the
two phones link up.

### How the Bluetooth link is built

Every phone plays two roles at once. It **announces** a small Earshot service (only when
"Visible to people nearby" is on), and it **looks for** that service on other phones.
The phone that finds the other one opens a Bluetooth connection and reads its *beacon*:
display name, session number and the rotating tag described below. Nothing else is
exchanged until a person asks to connect. All later bytes travel over that connection,
cut into small chunks (`BluetoothWire.swift`), and are encrypted by Earshot itself.
Earshot does not use Bluetooth pairing, so iOS never shows a pairing dialog.

### Simulator and Mac

The iOS Simulator has no Bluetooth. Simulator builds, and the `earshot-probe` Mac tool by
default, use Apple's MultipeerConnectivity over Wi‑Fi instead (`MultipeerTransport.swift`),
which only works in the foreground and asks for Local Network access. The Local Network
keys are compiled into Simulator builds only. Everything above the radio layer is identical.

## Who can see what

- **Your name** can be read by anyone nearby running Earshot while "Visible to people
  nearby" is on, including while Earshot is in the background. Turn the switch off to stop
  announcing; you can still find and contact others.
- **The Bluetooth broadcast itself** contains only the Earshot service number, the same
  for every Earshot phone. The name is not in the broadcast and Earshot never uses the
  device name ("Sam's iPhone").
- **Recognising saved contacts** uses a rotating tag (`DiscoveryTag` in `Crypto.swift`):
  a random number plus an HMAC of it keyed with your identity public key. Someone who
  already has your key (a contact) can match it; a stranger sees different random-looking
  bytes each session and cannot link them.
- **Message content, your identity key and the name in the identity proof** only ever
  travel inside the encrypted channel described below.
- **Nothing leaves the two phones.** There is no server, account, analytics or crash
  reporting. Messages are stored in the app's container and are excluded from iCloud and
  computer backups. The identity key is in the Keychain, marked "this device only".
- **Storage and the lock screen.** Stored chats and the identity key are encrypted by iOS
  until the phone has been unlocked once after a restart, and stay readable to Earshot
  after that. The stricter "only while unlocked" setting is not used because Earshot
  could then not save a message that arrives while the phone is locked.

## Connecting

1. **Request.** Alex taps Connect on Blake. Blake's phone shows a prompt with Alex's name.
   Until Blake accepts, nothing beyond the beacon and the request itself is exchanged.
   A decline, a timeout and "walked away" look the same to Alex: Earshot shows one
   message for all three, so declining never has to feel like a statement.
2. **Key exchange.** Each phone creates a one-time X25519 key and sends its public half.
   Both derive two ChaCha20‑Poly1305 keys (one per direction) with HKDF‑SHA256.
3. **Proof of identity.** Inside the encrypted channel, each phone sends its long-term
   Ed25519 public key, its display name and a signature over both one-time keys. The
   signature ties the identity to this one link, so a recorded proof cannot be replayed.
4. **Saved.** Both phones store the other's identity key as a contact.

### Reconnecting to a saved contact

No prompt is shown: both people agreed the first time. Instead, the phones are stricter
with each other:

- The reconnection invitation carries **no name**. It carries a tag (`PairTag` in
  `Crypto.swift`) computed from both identity keys and both phones' current session
  numbers. A stranger cannot forge it. If the receiving phone does not recognise it —
  for example because that person removed you — it is dropped silently. An automatic
  reconnection never turns into a prompt.

- Each phone first sends a **knock** (`Knock` in `Crypto.swift`): a MAC that can only be
  computed by someone who already holds *both* identity keys. Neither phone reveals its
  identity until it has seen a valid knock or a valid proof for the contact it expects.
  This stops someone who re-broadcasts a contact's beacon from harvesting your identity key.
- The identity proof must match the key stored for that contact, otherwise the link is
  closed and nothing is sent.

### Safety code

Every pair of contacts has a nine-digit code derived from both identity keys. If two
people compare it in person and it matches, nobody was sitting between their phones when
they first connected. This check is optional; without it, trust is "first contact".

## Messages and delivery states

Every message carries a random ID. The receiving phone stores it and returns a receipt.

| Status | Meaning |
| --- | --- |
| Waiting | The contact is not connected. Sent automatically when the phones link up again. |
| Sending | Handed to the link; no receipt yet. |
| Delivered | The other phone confirmed it received and stored the message. (Not "read".) |
| Not delivered | No receipt within 10 seconds on a live link (for example the other phone could not store it). Tap to retry. For photos the rule is different, see Photos below. |

If a link drops with messages in flight they return to Waiting and are re-sent after
reconnecting. The receiver ignores IDs it already has, so nothing is duplicated.

Each frame has a counter that must be exactly the next expected one; frames that are
replayed, skipped, re-ordered or modified close the link. Earshot then reconnects with
fresh keys. A link that delivers more than 60 messages in a burst (then 5 per second) is
closed, and a conversation keeps its most recent 5,000 messages.

## Formatting (shown on screen only)

Messages can carry light formatting. Nothing about it travels between phones: the raw
text the person typed is what is stored, sent, copied and shown in notifications, so every
Earshot version can read every message. Phones that understand formatting draw it.

| Typed | Shown |
| --- | --- |
| `*bold*` | **bold** |
| `_italic_` | *italic* |
| `~struck~` | ~~struck~~ |
| `` `code` `` | `code` (monospaced) |

The rules are strict so ordinary text is never mangled (`MessageFormatting.swift`):

- A marker opens only at the start of a word (after a space, punctuation or the start of
  the text) and closes only at the end of one. `snake_case_name` and `2*3*4` stay as typed.
- A style must open and close on the same line. Doubled markers (`**x**`) never count.
- Inside `` `code` `` everything is literal. Other styles may nest properly
  (`*bold _and italic_*`); if they cross, the inner one is shown as typed.
- Any marker without a partner is shown as typed: `see *you* at https://example.com/a_b ok_`
  shows "see **you** at", a link, and "ok_".

**Links.** Web addresses, email addresses and phone numbers are found on the phone with
Apple's `NSDataDetector` and drawn underlined. Text inside a link is never formatting, so
`https://a.com/x_y_z` stays intact. Only `http`, `https`, `mailto` and `tel` links are ever
opened, only when the person taps one, and always by iOS (Safari, Mail, Phone). Earshot
never loads a link itself and never fetches previews, so it still makes no network
requests. Long-pressing a message offers "Copy" for each link. VoiceOver reads a message
without the markers and offers each link as an action.

The conversation list and VoiceOver show messages without markers; notifications (when
message text is turned on) show the raw text.

## Photos

Two connected people can send each other photos over the same encrypted link.

**What happens, step by step**

1. **Picking.** The photo button opens Apple's photo picker. It runs outside Earshot and
   hands over only the one photo chosen, so Earshot asks for no photo-library permission.
   There is no camera button yet.
2. **Preparing** (on the sending phone, in the background, `PhotoProcessing.swift`): the
   photo is turned upright, scaled so its long side is at most 1,280 pixels, redrawn as a
   plain sRGB picture and saved as JPEG, stepping the quality (and then the size) down until
   it is at most about 150 KB. Hard limit: 400 KB, otherwise the photo is refused with a
   message. Then **every metadata block is removed from the file**: location, camera
   model, dates, comments, editing history and colour profile. A test feeds in a photo with
   GPS, camera, date and IPTC data and checks that none of it, nor any EXIF block, is left.
3. **Sending.** The photo goes in 4 KB pieces inside the existing encrypted channel. The
   receiving phone confirms each piece; the sender never has more than three unconfirmed,
   so a text message or receipt sent meanwhile waits behind at most about 16 KB of photo,
   never behind the whole photo. One photo per link at a time; others queue.
4. **Checking.** The receiver writes pieces straight to a file as they come (so even in
   the background the photo is never held in memory several times over), then checks the
   size, the SHA-256 of the whole file, and that it really is a complete JPEG of sane size —
   read from the file itself, never from what the sender claims, and before decoding it, so
   a small file pretending to be 50,000 × 50,000 pixels is refused unopened.
5. **Delivered.** Only then is the photo stored and the usual receipt sent. "Delivered" on a
   photo means fully received, checked and saved on the other phone.

**When things go wrong**

| Situation | What happens |
| --- | --- |
| The other person is not connected | The photo button explains that photos are only sent while connected. Unlike text, a new photo is not queued for later, so the person knows it is going now. |
| Their Earshot is an older version | The photo button explains that their Earshot can't receive photos yet. Text works as before. |
| The link drops halfway | The receiver throws away what it has. The sender's photo goes back to "Waiting" and starts again from the beginning the next time the phones link up (restart, not resume: simpler, and the receiver never keeps half a photo). If the new link is with a phone that no longer announces photos, it is marked not delivered instead of being sent. |
| No progress for 20 seconds on a live link | "Not delivered · The connection stalled". There is no fixed total time limit: a big photo on a slow link may take a minute and still succeed, as long as pieces keep arriving. |
| The other phone refuses it (too big, out of photo storage, failed checks) | "Not delivered · Their phone didn't accept it". |
| You tap ✕ while it is sending | "Cancelled"; the other phone throws its partial copy away. Tap to send it again. |

**Speed (expected, not measured on phones).** The pieces travel as JSON with base64, which
adds about a third, so a 100 KB photo is about 137 KB on the air. At 5–50 KB/s that is
about 3–28 seconds. The composer shows a range like this for the chosen photo. The probe
and the app log the real figure (bytes, seconds, KB/s, never content) when
`EARSHOT_BT_DEBUG` is set, so it can be measured on hardware.

**Limits.** No video: a short clip is several megabytes, which would take minutes over
Bluetooth LE. No camera capture yet. One photo per message, with an optional caption.

**Saving and sharing.** The full-screen viewer has a share button (Copy, Save to Files,
AirDrop, other apps). "Save Image" to the photo library is deliberately not offered: iOS
only shows it to apps that declare a photo-library "add" permission, which would bring a
permission prompt. Verified in the Simulator.

**Storage.** Each photo is one file in `Application Support/Earshot/attachments`, named
after its message, with the same protection as the rest of Earshot's data (encrypted until
the phone is first unlocked after a restart) and excluded from backups. Deleting the
message, clearing the conversation, removing the contact, the 5,000-message history limit
and "Erase everything" all delete the files. A photo half-received when the app stopped is
deleted at the next launch, and so is any file no message points to. Received photos are
limited to 300 MB in total; beyond that new ones are refused.

**Notifications** say "Photo" (or "Photo: caption") when message text is shown, and "New
message" otherwise, as for text. Photos arrive in the background over an open link the
same way text does.

**Hostile phones.** The receiver refuses a photo announced as larger than 1 MB before
setting anything aside, accepts at most two photos arriving at once per link, enforces the
storage limit, insists on pieces in order and never more bytes than announced, caps piece
size at 16 KB, limits photo bytes per link (2 MB burst, then 1 MB/s — far above Bluetooth,
it only stops floods over faster radios), and counts each announcement like a message
against the existing flood limit. A blocked contact cannot link, so cannot send anything.

### Photo wire format

For anyone implementing a compatible client (for example the web client). All of this
travels inside the encrypted channel as the JSON of `Payload`, exactly like text. Swift's
`JSONEncoder` defaults are used: `Data` is standard base64 with padding, UUIDs are
upper-case strings (any case is accepted), integers are plain JSON numbers, and an optional
field that is absent is left out. Key order is not significant. Unknown keys are ignored.

**Announcing support.** The identity proof gains an optional `features` list:

```json
{"auth":{"_0":{"identityKey":"…","name":"Alex","signature":"…","features":["photo-v1"]}}}
```

Phones before this change send no `features` key and ignore it when they receive it. Both
the first connection and the knock-based reconnection end with both phones sending `auth`,
so features are known on every link, and only what the current link announced is trusted.
A phone sends the payloads below **only** to a peer whose `auth` on the current link listed
`"photo-v1"`; an older phone cannot decode them and closes the link. A peer that does not
list it simply never receives photos. `Handshake.version` is still 1.

**Sender → receiver**

```json
{"photoStart":{"_0":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","size":104857,"sha256":"<32 bytes, base64>",
                     "width":1280,"height":960,"preview":"<optional JPEG ≤ 2048 bytes, base64>","caption":"optional"}}}
{"photoPiece":{"_0":{"id":"6F9619FF-…","index":0,"data":"<bytes, base64>"}}}
{"photoCancel":{"_0":"6F9619FF-…"}}
```

- `id` is the message ID; the final receipt is the ordinary `{"ack":{"_0":"<id>"}}`.
- `size` is the exact number of bytes of the file; `sha256` is SHA-256 over exactly those
  bytes (the whole JPEG file, nothing else, no length prefix).
- `width`, `height` and `preview` are hints for a placeholder only. `caption` follows the
  2,000-character message limit.
- Pieces are the file's bytes in order: `index` 0, 1, 2… with no gaps or repeats. This
  version sends 4,096 bytes per piece (the last one shorter); receivers accept 1–16,384.
- A sender keeps at most 3 pieces unconfirmed (receivers must not rely on this).

**Receiver → sender**

```json
{"photoProgress":{"_0":{"id":"6F9619FF-…","received":3}}}
{"photoRefuse":{"_0":"6F9619FF-…"}}
```

- `received` is how many pieces are stored so far, sent after each piece. It must grow and
  never exceed the number of pieces sent, or the sender closes the link.
- `photoRefuse` means "I will not take this photo" (too large, storage full, too many at
  once, hash or image check failed, gave up waiting). The sender marks it not delivered.
- If the photo is already stored (the receipt was lost), the receiver answers `photoStart`
  with an `ack` at once and ignores the pieces that follow.

**Closing the link** (protocol violation): a malformed `photoStart` (hash not 32 bytes, size
≤ 0, preview over 2,048 bytes, caption too long), a piece out of order, empty or over
16,384 bytes, more bytes than announced, a second `photoStart` for the same ID on the same
link, too many photo bytes or announcements too fast, progress beyond what was sent.

### Removing and blocking

- **Remove**: the contact and its messages are deleted. The other person's phone may keep
  trying to reconnect on its own; those attempts are ignored without a prompt. Either
  person can start again by tapping Connect, which shows the other a normal request.
- **Block**: the contact disappears from your lists and their phone can no longer link to
  yours. Because nothing about a person is known before a request is accepted, a blocked
  person can still appear as a *new* request under any name; accepting it fails at the
  identity check and no link forms. At most four unanswered requests are shown at once.

## What Earshot does not protect against

- **Recorded beacons.** The tag that lets contacts recognise each other can be recorded
  and re-broadcast later by someone else. Your phone will then try to reconnect to the
  impostor. The attempt carries no name and fails before your identity is revealed, but
  the fact that your phone reacted tells the impostor that you know that contact.

- A compromised or unlocked phone: messages are readable in the app by whoever holds it.
- Someone impersonating a *new* person by choosing the same name. Names are not unique;
  compare safety codes if it matters.
- Radio-level observers learning that *some* Earshot phones are nearby and talking,
  and how much data they exchange.
- The link encryption has not had an independent security audit.
- Keys are fresh for every link, so capturing one link's keys does not expose earlier
  links. Within one long-lived link the keys are not rotated.

## Code map

| File | Role |
| --- | --- |
| `Models.swift` | Contacts, messages, link and request states. |
| `Crypto.swift` | Identity, key exchange, encrypted channel, discovery tag, knock, safety code. |
| `Wire.swift` | Frame and payload formats. |
| `Transport.swift` | The radio abstraction: discover, invite, send bytes. |
| `BluetoothTransport.swift` | The radio layer on real iPhones (Bluetooth LE, works in the background). |
| `BluetoothWire.swift` | Beacon, chunking and frame formats for Bluetooth. |
| `MultipeerTransport.swift` | The radio layer for the Simulator and Mac testing (MultipeerConnectivity). |
| `Live.swift` | Chooses the radio layer and builds the real `Messenger`. |
| `LoopbackTransport.swift` | In-memory radio for tests and demo mode. |
| `Messenger.swift` | The engine: consent, handshake, delivery, reconnection, storage. |
| `Messenger+Photos.swift` | Sending and receiving photos: pacing, checks, timeouts, clean-up. |
| `PhotoWire.swift` | Photo payloads, the `photo-v1` feature, and every photo limit (`PhotoLimits`). |
| `PhotoProcessing.swift` | Shrinking and cleaning photos before sending, checking received ones, safe decoding. |
| `AttachmentStore.swift` | Photo files on disk (or in memory for tests and demo mode). |
| `MessageFormatting.swift` | Finds links and bold, italic, strikethrough and code markers in message text, for display. |
| `Persistence.swift` | On-disk storage and Keychain. |
| `DemoWorld.swift` | Simulated neighbours for previews, screenshots and UI tests (`-demo` only). |
