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
| How fast is it? | Slow by internet standards but enough for text. Expect a short message to arrive almost at once on an open link and a 2,000-character message to take a few seconds (not yet measured on hardware). |

### Background delivery: what works and what does not

Earshot declares the `bluetooth-central` and `bluetooth-peripheral` background modes.
The rules below are iOS rules, not Earshot choices.

> **Verification status.** The table describes how the code is built to behave under
> Apple's documented Core Bluetooth background rules. The Bluetooth layer compiles for
> iPhone and its byte formats are unit-tested, but it has **not yet been run between two
> physical iPhones**. Treat timings and the "works" rows as expected, not measured, until
> the hardware checklist in the README has been completed.

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
| Not delivered | No receipt within 10 seconds on a live link (for example the other phone could not store it). Tap to retry. |

If a link drops with messages in flight they return to Waiting and are re-sent after
reconnecting. The receiver ignores IDs it already has, so nothing is duplicated.

Each frame has a counter that must be exactly the next expected one; frames that are
replayed, skipped, re-ordered or modified close the link. Earshot then reconnects with
fresh keys. A link that delivers more than 60 messages in a burst (then 5 per second) is
closed, and a conversation keeps its most recent 5,000 messages.

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
| `Persistence.swift` | On-disk storage and Keychain. |
| `DemoWorld.swift` | Simulated neighbours for previews, screenshots and UI tests (`-demo` only). |
