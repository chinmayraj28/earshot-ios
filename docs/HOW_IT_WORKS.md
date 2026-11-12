# How Earshot works

This document explains what happens between two phones, what the platform allows, and
what Earshot does and does not protect against. It is written to be checked against the
code in `EarshotKit/Sources/EarshotKit`.

## The radio layer and its limits

Earshot uses Apple's **MultipeerConnectivity** framework (`MultipeerTransport.swift`).
iOS carries it over peer-to-peer Wi‑Fi and Bluetooth, directly between the two phones.

| Question | Answer |
| --- | --- |
| Does it need internet, a router or mobile signal? | No. |
| What must be switched on? | Wi‑Fi and Bluetooth, on both phones. They can be on in Airplane Mode. |
| How far does it reach? | The phones' own radios: the same room or a few rooms. Walls, bodies and crowds shorten it. Earshot does not promise a distance. |
| Does it work with the app closed? | **No.** iOS stops nearby discovery and closes open links shortly after an app leaves the foreground. Both people need Earshot open. |
| Are messages relayed through other phones? | No. Earshot is direct, phone to phone. It is not a mesh network. |
| What permission does iOS ask for? | Local Network, once, when Earshot is first switched on. Nothing else. |
| Why not plain Bluetooth (Core Bluetooth)? | Bluetooth LE background modes exist, but iOS throttles them heavily, hides the app's advertised service from other phones when backgrounded, and offers very low data rates. It would let Earshot *claim* background messaging without delivering it reliably. |

What happens to a message when the other person is not reachable: it is stored on the
sender's phone with the status **Waiting** and is sent automatically the next time both
phones have Earshot open near each other.

## Who can see what

- **Your name** is announced to anyone nearby running Earshot while the app is open and
  "Visible to people nearby" is on. Turn the switch off to stop announcing; you can still
  find and contact others.
- **The system-level peer name** MultipeerConnectivity broadcasts is a random handle that
  changes on every start. Earshot never broadcasts the device name.
- **Recognising saved contacts** uses a rotating tag (`DiscoveryTag` in `Crypto.swift`):
  a random number plus an HMAC of it keyed with your identity public key. Someone who
  already has your key (a contact) can match it; a stranger sees different random-looking
  bytes each session and cannot link them.
- **Message content, your identity key and the name in the identity proof** only ever
  travel inside the encrypted channel described below.
- **Nothing leaves the two phones.** There is no server, account, analytics or crash
  reporting. Messages are stored in the app's container with iOS file protection and are
  excluded from iCloud and computer backups. The identity key is in the Keychain, marked
  "this device only".

## Connecting

1. **Request.** Alex taps Connect on Blake. Blake's phone shows a prompt with Alex's name.
   Until Blake accepts, no radio link exists and nothing else is exchanged.
   iOS reports a decline, a timeout and "walked away" identically, so Earshot shows one
   honest message for all three.
2. **Key exchange.** Each phone creates a one-time X25519 key and sends its public half.
   Both derive two ChaCha20‑Poly1305 keys (one per direction) with HKDF‑SHA256.
3. **Proof of identity.** Inside the encrypted channel, each phone sends its long-term
   Ed25519 public key, its display name and a signature over both one-time keys. The
   signature ties the identity to this one link, so a recorded proof cannot be replayed.
4. **Saved.** Both phones store the other's identity key as a contact.

### Reconnecting to a saved contact

No prompt is shown: both people agreed the first time. Instead, the phones are stricter
with each other:

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
| Waiting | The contact is not connected. Sent automatically on reconnect while Earshot is open. |
| Sending | Handed to the link; no receipt yet. |
| Delivered | The other phone confirmed it received and stored the message. (Not "read".) |
| Not delivered | No receipt within 10 seconds on a live link. Tap to retry. |

If a link drops with messages in flight they return to Waiting and are re-sent after
reconnecting. The receiver ignores IDs it already has, so nothing is duplicated.

Each frame has a counter; frames that are replayed, re-ordered or modified fail
authentication and close the link. Earshot then reconnects with fresh keys.

## What Earshot does not protect against

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
| `MultipeerTransport.swift` | The real radio layer (MultipeerConnectivity). |
| `LoopbackTransport.swift` | In-memory radio for tests and demo mode. |
| `Messenger.swift` | The engine: consent, handshake, delivery, reconnection, storage. |
| `Persistence.swift` | On-disk storage and Keychain. |
| `DemoWorld.swift` | Simulated neighbours for previews, screenshots and UI tests (`-demo` only). |
