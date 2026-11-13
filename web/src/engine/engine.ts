/**
 * The real Earshot engine for the browser. It mirrors `Messenger` in
 * EarshotKit/Sources/EarshotKit/Messenger.swift, in the INVITER role only: a browser cannot
 * announce itself, so it always starts the Bluetooth connection and never receives a request.
 *
 * One link to a phone goes through these steps (compare `Messenger.Link.Phase`):
 *
 *   opening        Bluetooth connect, subscribe to the outbox, read the beacon.
 *   inviting       Invitation written. A new phone shows its person a prompt; a saved contact
 *                  (recognised by the beacon's DiscoveryTag) gets a PairTag instead and accepts silently.
 *   awaitingHello  Accepted. Both sides send their one-time key ("hello").
 *   awaitingAuth   Channel encrypted. A new phone: both send their identity proof ("auth") at once.
 *                  A saved contact: both first send a "knock"; each reveals itself only after a valid one.
 *   established    Messages and receipts flow. Waiting messages are sent now.
 *
 * Example: Alex clicks "Find nearby", picks Jensen's iPhone. Jensen taps Accept. A few hundred
 * milliseconds later both screens show the same safety code and Alex's queued messages go out.
 */
import type { Availability, ConnectionRequest, ContactID, FindResult, LinkState, MessageID, PeerToken } from "./api";
import { bytesEqual, randomBytes } from "./bytes";
import {
  DISCOVERY_NONCE_LENGTH,
  DISCOVERY_TAG_LENGTH,
  HANDSHAKE_VERSION,
  Handshake,
  contactIDFor,
  discoveryTag,
  handshakeTranscript,
  identityFromSeed,
  knock,
  newIdentity,
  pairTag,
  sign,
  verifySignature,
  type Identity,
  type SecureChannel,
} from "./crypto";
import { debug, errorKind } from "./log";
import { EngineState } from "./state";
import { MemoryStorage, type Storage } from "./storage";
import { isValidMessageText, sanitizedName } from "./text";
import { ConnectError, DEFAULT_CHUNK_LENGTH, FramedLink, type Device, type Transport } from "./transport";
import {
  FrameKind,
  decodeFrame,
  decodePayload,
  encodeHello,
  encodeInviteBody,
  encodeInviteContext,
  encodePayload,
  encodeSealed,
  parseBeacon,
  type Beacon,
  type InviteContext,
  type Payload,
} from "./wire";

export interface EngineConfig {
  /** How long to wait for a delivery receipt before marking a message failed. */
  ackTimeoutMs: number;
  /** How long the key exchange and identity proof may take after the phone accepted. */
  handshakeTimeoutMs: number;
  /** How long the person holding the phone has to answer a request. */
  inviteTimeoutMs: number;
  /** Waits between automatic re-link attempts after a link to a contact dropped. Then we give up. */
  reconnectDelaysMs: number[];
  /** A link may deliver this many messages in a burst, then `incomingRate` per second. */
  incomingBurst: number;
  incomingRate: number;
  /** Bluetooth chunk size, marker byte included. See transport.ts. */
  chunkLength: number;
}

export const defaultConfig: EngineConfig = {
  ackTimeoutMs: 10_000,
  handshakeTimeoutMs: 12_000,
  inviteTimeoutMs: 45_000,
  reconnectDelaysMs: [1_000, 2_000, 4_000, 8_000, 8_000],
  incomingBurst: 60,
  incomingRate: 5,
  chunkLength: DEFAULT_CHUNK_LENGTH,
};

export interface EngineOptions {
  transport: Transport;
  storage: Storage;
  config?: Partial<EngineConfig>;
  now?: () => number;
  /** Send "bye" when the tab closes (`pagehide`). Default: true when running in a browser window. */
  listenToPageLifecycle?: boolean;
}

/** Why a link ended. Mirrors `Messenger.LinkFailure`, plus the cases a radio reports. */
type Failure =
  | "protocolViolation"
  | "verificationFailed"
  | "incompatibleVersion"
  | "refused"
  | "remoteLeft"
  | "timedOut"
  /** The phone answered the invitation with "decline" (or its prompt expired). */
  | "declined"
  /** The Bluetooth connection dropped or could not be opened. */
  | "connectionLost"
  /** We closed it on purpose (disconnect, dismiss, block, remove, erase). */
  | "local";

class LinkFailure extends Error {
  constructor(readonly failure: Failure) {
    super(failure);
  }
}

type Phase =
  | { kind: "opening" }
  | { kind: "inviting" }
  | { kind: "awaitingHello"; handshake: Handshake }
  | { kind: "awaitingAuth"; localEphemeral: Uint8Array; remoteEphemeral: Uint8Array }
  | { kind: "established"; contactID: ContactID };

interface Link {
  /** Unique per link, so timers from an earlier link to the same phone do nothing. */
  readonly serial: number;
  readonly token: PeerToken;
  readonly device: Device;
  readonly framed: FramedLink;
  /** The saved contact we believe this is. The identity proof must match it. */
  expected: ContactID | null;
  /** True for a request to someone new, started by a click. Only those may create a contact. */
  userInitiated: boolean;
  phase: Phase;
  channel: SecureChannel | null;
  /** Whether we have revealed our identity on this link yet. */
  authSent: boolean;
  beacon: Beacon | null;
  /** Allowance for incoming messages; refills over time. Stops a flood from one link. */
  budget: number;
  budgetAt: number;
  timers: Array<ReturnType<typeof setTimeout>>;
}

interface Reconnect {
  attempt: number;
  timer: ReturnType<typeof setTimeout> | null;
}

export class EarshotEngine extends EngineState {
  readonly #transport: Transport;
  #storage: Storage;
  readonly #config: EngineConfig;
  #identity: Identity = newIdentity();
  /** This tab's session number, sent with every invitation. */
  readonly #localNonce = randomBytes(DISCOVERY_NONCE_LENGTH);
  #links = new Map<PeerToken, Link>();
  #serial = 0;
  /** The phone each contact was last reached on in this tab. Re-connecting to it needs no click. */
  #devices = new Map<ContactID, Device>();
  #reconnects = new Map<ContactID, Reconnect>();
  /** Contacts the person disconnected on purpose: no automatic re-link until they pick the phone again. */
  #manuallyDisconnected = new Set<ContactID>();
  #ready: Promise<void> | null = null;
  #storageChain: Promise<unknown> = Promise.resolve();
  #queuedSaves = new Map<ContactID, Promise<boolean>>();
  #unsubscribers: Array<() => void> = [];
  readonly #listenToPage: boolean;

  constructor(options: EngineOptions) {
    super(options.now);
    this.#transport = options.transport;
    this.#storage = options.storage;
    this.#config = { ...defaultConfig, ...options.config };
    this.#listenToPage = options.listenToPageLifecycle ?? typeof window !== "undefined";
  }

  // MARK: Start-up

  ready(): Promise<void> {
    if (!this.#ready) this.#ready = this.#load();
    return this.#ready;
  }

  async #load(): Promise<void> {
    let state;
    try {
      state = await this.#storage.load();
    } catch (error) {
      // IndexedDB unusable (for example blocked by browser settings). Run without saving anything,
      // rather than overwriting a stored identity we merely could not read.
      debug("storage", "load failed; nothing will be saved this session", { error: errorKind(error) });
      this.#storage = new MemoryStorage();
      state = await this.#storage.load();
    }
    if (state.identitySeed) {
      this.#identity = identityFromSeed(state.identitySeed);
    } else {
      this.#identity = newIdentity();
      this.#write(() => this.#storage.saveIdentity(this.#identity.seed));
    }
    this.profile = state.profile;
    this.contacts = state.contacts;
    this.conversations = new Map();
    for (const [id, stored] of state.conversations) {
      // Anything still "sending" when the tab last closed never got a receipt.
      const messages = stored.messages.map((m) => (m.status === "sending" ? { ...m, status: "waiting" as const } : m));
      this.conversations.set(id, { messages, unreadCount: stored.unreadCount });
      this.knownMessageIDs.set(id, new Set(messages.map((m) => m.id)));
    }
    this.availability = await this.#transport.availability();
    this.#unsubscribers.push(
      this.#transport.onAvailabilityChanged((availability) => this.#availabilityChanged(availability)),
    );
    if (this.#listenToPage && typeof window !== "undefined") {
      const onPageHide = () => this.#sayGoodbye();
      window.addEventListener("pagehide", onPageHide);
      this.#unsubscribers.push(() => window.removeEventListener("pagehide", onPageHide));
    }
    this.changed();
  }

  /** Stops listening to the page and the radio. For tests; the app keeps one engine for its lifetime. */
  dispose(): void {
    for (const link of [...this.#links.values()]) this.#drop(link, "local");
    for (const id of [...this.#reconnects.keys()]) this.#cancelReconnect(id);
    this.#unsubscribers.forEach((u) => u());
    this.#unsubscribers = [];
  }

  #availabilityChanged(availability: Availability): void {
    if (availability === this.availability) return;
    this.availability = availability;
    this.changed();
  }

  /** Best effort when the tab closes: tell every connected phone we are leaving. */
  #sayGoodbye(): void {
    for (const link of this.#links.values()) {
      if (link.phase.kind === "established") {
        try {
          this.#sendPayload(link, { kind: "bye" });
        } catch {
          // The link is already gone.
        }
      }
      if (!link.framed.isClosed) link.framed.send(FrameKind.close).catch(() => {});
    }
  }

  // MARK: Reading state

  protected ownIdentityKey(): Uint8Array {
    return this.#identity.publicKey;
  }

  /** This browser's identity public key (32 bytes). */
  get identityKey(): Uint8Array {
    return this.#identity.publicKey;
  }

  protected linkState(id: ContactID): LinkState {
    let state: LinkState = "outOfRange";
    for (const link of this.#links.values()) {
      if (link.phase.kind === "established" && link.phase.contactID === id) return "connected";
      if (link.expected === id) state = "connecting";
    }
    if (this.#reconnects.get(id)?.timer) state = "connecting";
    return state;
  }

  #linkTo(id: ContactID): Link | undefined {
    for (const link of this.#links.values()) {
      if ((link.phase.kind === "established" && link.phase.contactID === id) || link.expected === id) return link;
    }
    return undefined;
  }

  #establishedLink(id: ContactID): Link | undefined {
    for (const link of this.#links.values()) {
      if (link.phase.kind === "established" && link.phase.contactID === id) return link;
    }
    return undefined;
  }

  // MARK: Finding a phone

  async findNearby(): Promise<FindResult> {
    await this.ready();
    if (this.finding) return { kind: "cancelled" };
    if (!this.profile.displayName || this.availability === "unsupported" || this.availability === "insecure") {
      return { kind: "failed", reason: "unavailable" };
    }
    this.finding = true;
    this.changed();
    try {
      const choice = await this.#transport.choose();
      if (choice.kind === "cancelled") return { kind: "cancelled" };
      if (choice.kind === "failed") return { kind: "failed", reason: "unavailable" };
      return await this.#openPicked(choice.device);
    } catch (error) {
      debug("find", "unexpected failure", { error: errorKind(error) });
      return { kind: "failed", reason: "unreachable" };
    } finally {
      this.finding = false;
      this.changed();
    }
  }

  async #openPicked(device: Device): Promise<FindResult> {
    const existing = this.#links.get(device.token);
    if (existing) {
      const id = existing.phase.kind === "established" ? existing.phase.contactID : existing.expected;
      return { kind: "started", peer: device.token, contactID: id };
    }
    const link = this.#newLink(device, null, true);
    const opened = await this.#open(link);
    if (opened !== "ok") return { kind: "failed", reason: opened };
    const beacon = link.beacon!;
    const contact = this.#recognise(beacon);
    if (contact) {
      if (contact.isBlocked) {
        // Never connect to a blocked contact.
        this.#drop(link, "local");
        return { kind: "failed", reason: "unavailable" };
      }
      const other = this.#linkTo(contact.id);
      if (other && other !== link) {
        this.#drop(link, "local");
        return { kind: "started", peer: other.token, contactID: contact.id };
      }
      // A saved contact: reconnect silently, as the phone app does.
      this.#manuallyDisconnected.delete(contact.id);
      this.#cancelReconnect(contact.id);
      this.#devices.set(contact.id, device);
      link.expected = contact.id;
      link.userInitiated = false;
      this.#invite(link);
      this.changed();
      return { kind: "started", peer: device.token, contactID: contact.id };
    }
    const name = sanitizedName(beacon.displayName);
    if (!name) {
      this.#drop(link, "local");
      return { kind: "failed", reason: "notEarshot" };
    }
    const request: ConnectionRequest = { id: device.token, displayName: name, state: { kind: "waiting" } };
    this.requests = [...this.requests.filter((r) => r.id !== device.token), request];
    this.#invite(link);
    this.changed();
    return { kind: "started", peer: device.token, contactID: null };
  }

  #newLink(device: Device, expected: ContactID | null, userInitiated: boolean): Link {
    const serial = ++this.#serial;
    const link: Link = {
      serial,
      token: device.token,
      device,
      framed: new FramedLink(
        {
          onFrame: (kind, body) => {
            if (this.#links.get(device.token) === link) this.#btFrameReceived(link, kind, body);
          },
          onFailed: (reason) => {
            debug("link", "connection failed", { reason });
            if (this.#links.get(device.token) === link) this.#drop(link, "connectionLost");
          },
        },
        this.#config.chunkLength,
      ),
      expected,
      userInitiated,
      phase: { kind: "opening" },
      channel: null,
      authSent: false,
      beacon: null,
      budget: 0,
      budgetAt: 0,
      timers: [],
    };
    this.#links.set(device.token, link);
    return link;
  }

  /** Connects and reads the beacon. On failure the link is removed and the reason returned. */
  async #open(link: Link): Promise<"ok" | "notEarshot" | "unreachable"> {
    try {
      const connection = await link.device.connect(link.framed.gattHandlers);
      if (this.#links.get(link.token) !== link) {
        // Cancelled (dismissed, erased) while connecting.
        connection.disconnect();
        return "unreachable";
      }
      link.framed.attach(connection);
      const beacon = parseBeacon(connection.beacon);
      if (!beacon) {
        this.#drop(link, "local");
        return "notEarshot";
      }
      link.beacon = beacon;
      return "ok";
    } catch (error) {
      const reason = error instanceof ConnectError ? error.reason : "unreachable";
      if (this.#links.get(link.token) === link) {
        this.#links.delete(link.token);
        link.framed.close();
      }
      return reason;
    }
  }

  /** The saved contact whose identity key produced this beacon's tag, if any. */
  #recognise(beacon: Beacon) {
    if (beacon.nonce.length !== DISCOVERY_NONCE_LENGTH || beacon.tag.length !== DISCOVERY_TAG_LENGTH) return undefined;
    return this.contacts.find((c) => bytesEqual(discoveryTag(c.identityKey, beacon.nonce), beacon.tag));
  }

  #invite(link: Link): void {
    const beacon = link.beacon!;
    const context: InviteContext = { v: 1, nonce: this.#localNonce };
    const contact = link.expected ? this.contact(link.expected) : undefined;
    if (contact) {
      // Reconnecting: no name, just a tag only this contact can check.
      context.tag = pairTag(this.#identity.publicKey, contact.identityKey, this.#localNonce, beacon.nonce);
    } else {
      context.name = this.profile.displayName;
    }
    link.phase = { kind: "inviting" };
    link.framed
      .send(FrameKind.invite, encodeInviteBody(this.#localNonce, encodeInviteContext(context)))
      .catch(() => {}); // A failed write is reported through FramedLink.onFailed.
    this.#after(link, this.#config.inviteTimeoutMs, () => {
      if (link.phase.kind === "inviting") this.#drop(link, "timedOut");
    });
  }

  // MARK: Frames from the phone

  #btFrameReceived(link: Link, kind: FrameKind, body: Uint8Array): void {
    switch (kind) {
      case FrameKind.accept:
        if (link.phase.kind === "inviting") this.#accepted(link);
        break;
      case FrameKind.decline:
        if (link.phase.kind === "inviting") this.#drop(link, "declined");
        break;
      case FrameKind.data:
        // Like the phone, data only counts once the invitation was accepted.
        if (link.phase.kind !== "opening" && link.phase.kind !== "inviting") this.#frameReceived(link, body);
        break;
      case FrameKind.close:
        if (link.phase.kind !== "opening" && link.phase.kind !== "inviting") this.#drop(link, "connectionLost", false);
        break;
      default:
        // A phone never sends "invite" to the device that connected to it. Ignored, as on iOS.
        break;
    }
  }

  #accepted(link: Link): void {
    const handshake = new Handshake();
    link.phase = { kind: "awaitingHello", handshake };
    this.updateRequest(link.token, (r) => (r.state.kind === "waiting" ? { ...r, state: { kind: "connecting" } } : r));
    link.framed.send(FrameKind.data, encodeHello(HANDSHAKE_VERSION, handshake.publicKey)).catch(() => {});
    this.#after(link, this.#config.handshakeTimeoutMs, () => {
      if (link.phase.kind !== "established") this.#drop(link, "timedOut");
    });
    this.changed();
  }

  #frameReceived(link: Link, data: Uint8Array): void {
    try {
      const frame = decodeFrame(data);
      if (frame.kind === "hello") {
        if (link.phase.kind !== "awaitingHello") throw new LinkFailure("protocolViolation");
        if (frame.version !== HANDSHAKE_VERSION) throw new LinkFailure("incompatibleVersion");
        const handshake = link.phase.handshake;
        link.channel = handshake.channel(frame.ephemeralKey);
        link.phase = { kind: "awaitingAuth", localEphemeral: handshake.publicKey, remoteEphemeral: frame.ephemeralKey };
        const contact = link.expected ? this.contact(link.expected) : undefined;
        if (contact) {
          // Reconnecting to a saved contact: stay anonymous until the phone shows it knows us.
          this.#sendPayload(link, {
            kind: "knock",
            knock: knock(this.#identity.publicKey, contact.identityKey, handshake.publicKey, frame.ephemeralKey),
          });
        } else {
          // A new person, and someone here clicked to connect.
          this.#sendAuth(link);
        }
      } else {
        if (!link.channel) throw new LinkFailure("protocolViolation");
        const plaintext = link.channel.open(frame.box);
        this.#payloadReceived(link, decodePayload(plaintext));
      }
    } catch (error) {
      if (this.#links.get(link.token) !== link) return;
      const failure = error instanceof LinkFailure ? error.failure : "protocolViolation";
      debug("link", "closing link", { failure });
      this.#drop(link, failure);
    }
  }

  #payloadReceived(link: Link, payload: Payload): void {
    const phase = link.phase;
    if (payload.kind === "knock" && phase.kind === "awaitingAuth") {
      // Only matters while we are still holding back our identity.
      const contact = link.expected ? this.contact(link.expected) : undefined;
      if (link.authSent || !contact) return;
      const valid = knock(this.#identity.publicKey, contact.identityKey, phase.remoteEphemeral, phase.localEphemeral);
      if (!bytesEqual(payload.knock, valid)) throw new LinkFailure("verificationFailed");
      this.#sendAuth(link);
      return;
    }
    if (payload.kind === "auth" && phase.kind === "awaitingAuth") {
      const transcript = handshakeTranscript(phase.remoteEphemeral, phase.localEphemeral);
      if (
        payload.identityKey.length !== 32 ||
        bytesEqual(payload.identityKey, this.#identity.publicKey) ||
        !verifySignature(payload.signature, transcript, payload.identityKey)
      ) {
        throw new LinkFailure("verificationFailed");
      }
      this.#establish(link, payload.identityKey, payload.name);
      return;
    }
    if (payload.kind === "text" && phase.kind === "established") {
      this.#textReceived(link, phase.contactID, payload.id, payload.text);
      return;
    }
    if (payload.kind === "ack" && phase.kind === "established") {
      const id = phase.contactID;
      const message = this.messages(id).find((m) => m.id === payload.id);
      if (message && message.direction === "outgoing" && message.status !== "delivered") {
        this.setStatus(id, payload.id, "delivered");
        void this.persistConversation(id);
        this.changed();
      }
      return;
    }
    if (payload.kind === "bye" && phase.kind === "established") throw new LinkFailure("remoteLeft");
    throw new LinkFailure("protocolViolation");
  }

  #textReceived(link: Link, id: ContactID, messageID: MessageID, text: string): void {
    if (!isValidMessageText(text)) throw new LinkFailure("protocolViolation");
    this.#chargeIncomingMessage(link);
    if (this.knownMessageIDs.get(id)?.has(messageID)) {
      // A repeat: the first receipt may have been lost, so confirm again.
      this.#sendPayload(link, { kind: "ack", id: messageID });
      return;
    }
    const message = { id: messageID, direction: "incoming" as const, text, timestamp: this.now(), status: "delivered" as const };
    this.appendMessage(id, message, this.activeConversation !== id);
    this.emit({ kind: "messageReceived", contactID: id, message });
    this.changed();
    // "Delivered" means stored. The receipt goes out only once the save has succeeded.
    void this.persistConversation(id).then((stored) => {
      if (!stored || this.#links.get(link.token) !== link || link.phase.kind !== "established") return;
      try {
        this.#sendPayload(link, { kind: "ack", id: messageID });
      } catch {
        // The link closed meanwhile; the phone will resend and we will confirm then.
      }
    });
  }

  #chargeIncomingMessage(link: Link): void {
    const now = this.now();
    const elapsed = Math.max(0, now - link.budgetAt) / 1000;
    link.budget = Math.min(this.#config.incomingBurst, link.budget + elapsed * this.#config.incomingRate);
    link.budgetAt = now;
    if (link.budget < 1) throw new LinkFailure("protocolViolation");
    link.budget -= 1;
  }

  #establish(link: Link, identityKey: Uint8Array, name: string): void {
    const id = contactIDFor(identityKey);
    if (link.expected && link.expected !== id) throw new LinkFailure("verificationFailed");
    const cleanName = sanitizedName(name);
    if (!cleanName) throw new LinkFailure("protocolViolation");

    const known = this.contact(id);
    if (known) {
      if (known.isBlocked) throw new LinkFailure("refused");
      if (known.displayName !== cleanName) this.replaceContact({ ...known, displayName: cleanName });
    } else {
      // A new person only becomes a contact when someone here asked for it.
      if (!link.userInitiated) throw new LinkFailure("verificationFailed");
      this.contacts = [
        ...this.contacts,
        { id, displayName: cleanName, identityKey: identityKey.slice(), addedAt: this.now(), isBlocked: false, isVerified: false },
      ];
      if (!this.conversations.has(id)) this.conversations.set(id, { messages: [], unreadCount: 0 });
      this.persistContacts();
    }

    // One link per contact; the newest wins.
    for (const other of [...this.#links.values()]) {
      if (other === link) continue;
      if ((other.phase.kind === "established" && other.phase.contactID === id) || other.expected === id) {
        this.#links.delete(other.token);
        this.#clearTimers(other);
        this.#closeQuietly(other);
      }
    }
    // They have proven who they are. If we were holding back, prove ourselves now.
    if (!link.authSent) this.#sendAuth(link);
    link.phase = { kind: "established", contactID: id };
    link.budget = this.#config.incomingBurst;
    link.budgetAt = this.now();
    this.#clearTimers(link);
    this.#devices.set(id, link.device);
    this.#cancelReconnect(id);
    this.updateRequest(link.token, (r) => ({ ...r, state: { kind: "connected", contactID: id } }));
    this.emit({ kind: "connected", contactID: id });
    for (const message of this.messages(id)) {
      if (message.direction === "outgoing" && (message.status === "waiting" || message.status === "sending")) {
        this.transmit(id, message.id);
      }
    }
    void this.persistConversation(id);
    this.changed();
  }

  // MARK: Sending

  #sendPayload(link: Link, payload: Payload): void {
    if (!link.channel || link.framed.isClosed) throw new LinkFailure("protocolViolation");
    const sealed = link.channel.seal(encodePayload(payload));
    link.framed.send(FrameKind.data, encodeSealed(sealed)).catch(() => {});
  }

  /** Reveals this browser's identity to the phone and proves it with a signature. */
  #sendAuth(link: Link): void {
    const phase = link.phase;
    if (phase.kind !== "awaitingAuth") throw new LinkFailure("protocolViolation");
    const transcript = handshakeTranscript(phase.localEphemeral, phase.remoteEphemeral);
    link.authSent = true;
    this.#sendPayload(link, {
      kind: "auth",
      identityKey: this.#identity.publicKey,
      name: this.profile.displayName,
      signature: sign(this.#identity, transcript),
    });
  }

  protected transmit(id: ContactID, messageID: MessageID): void {
    const message = this.messages(id).find((m) => m.id === messageID);
    const link = this.#establishedLink(id);
    if (!message || !link) return;
    // Mark it first: on a fast link the receipt can arrive before the write finishes.
    this.setStatus(id, messageID, "sending");
    try {
      this.#sendPayload(link, { kind: "text", id: message.id, text: message.text });
    } catch {
      // The link is gone but we were not told yet. Park the message; it goes out on reconnect.
      this.setStatus(id, messageID, "waiting");
      this.#drop(link, "protocolViolation");
      return;
    }
    this.#after(link, this.#config.ackTimeoutMs, () => {
      if (this.messages(id).find((m) => m.id === messageID)?.status !== "sending") return;
      this.setStatus(id, messageID, "failed");
      void this.persistConversation(id);
      this.changed();
    });
  }

  protected afterQueued(id: ContactID): void {
    // Not linked, but we know which phone it was: try again now, without a click.
    if (!this.#linkTo(id) && !this.#reconnects.get(id)?.timer && !this.#manuallyDisconnected.has(id)) {
      this.#startReconnect(id);
    }
  }

  // MARK: Ending links

  /**
   * Ends a link: forgets it, tells the phone ("close") unless the phone closed it, lets the
   * Bluetooth connection go, then updates requests, messages and re-linking.
   */
  #drop(link: Link, failure: Failure, tellPhone = true): void {
    if (this.#links.get(link.token) !== link) return;
    this.#links.delete(link.token);
    this.#clearTimers(link);
    // Before the invitation nothing was said to the phone, so there is nothing to close there.
    if (tellPhone && link.phase.kind !== "opening") this.#closeQuietly(link);
    else link.framed.close();
    this.#linkEnded(link, failure);
    this.changed();
  }

  /** Writes "close" (after anything already queued, such as "bye"), then disconnects. */
  #closeQuietly(link: Link): void {
    const framed = link.framed;
    if (framed.isClosed) return;
    const done = () => framed.close();
    const timer = setTimeout(done, 1_500);
    framed
      .send(FrameKind.close)
      .catch(() => {})
      .finally(() => {
        clearTimeout(timer);
        done();
      });
  }

  #linkEnded(link: Link, failure: Failure): void {
    if (link.phase.kind === "established") {
      const id = link.phase.contactID;
      this.parkUnconfirmedMessages(id);
      if (failure !== "local") this.#scheduleReconnect(id);
      return;
    }
    this.updateRequest(link.token, (request) => {
      const state = request.state.kind;
      if (state !== "waiting" && state !== "connecting") return request;
      let next: ConnectionRequest["state"];
      if (failure === "verificationFailed" || failure === "refused") next = { kind: "failed", failure: "verificationFailed" };
      else if (failure === "incompatibleVersion") next = { kind: "failed", failure: "incompatibleVersion" };
      else {
        // A decline, a timeout and "walked away" look the same, on purpose.
        const unanswered = state === "waiting" && (failure === "declined" || failure === "timedOut" || failure === "connectionLost");
        next = { kind: "failed", failure: unanswered ? "noAnswer" : "connectionLost" };
      }
      return { ...request, state: next };
    });
    if (!link.userInitiated && link.expected && failure !== "verificationFailed" && failure !== "refused" && failure !== "local") {
      this.#scheduleReconnect(link.expected);
    }
  }

  dismiss(request: PeerToken): void {
    if (!this.requests.some((r) => r.id === request)) return;
    this.requests = this.requests.filter((r) => r.id !== request);
    const link = this.#links.get(request);
    if (link && link.phase.kind !== "established") this.#drop(link, "local");
    this.changed();
  }

  disconnect(id: ContactID): void {
    this.#manuallyDisconnected.add(id);
    this.#cancelReconnect(id);
    for (const link of [...this.#links.values()]) {
      const linked = link.phase.kind === "established" && link.phase.contactID === id;
      if (!linked && link.expected !== id) continue;
      if (linked) {
        try {
          this.#sendPayload(link, { kind: "bye" });
        } catch {
          // already closed
        }
      }
      this.#drop(link, "local");
    }
    this.parkUnconfirmedMessages(id);
    this.changed();
  }

  protected closeLinks(id: ContactID, reason: "blocked" | "removed"): void {
    this.#cancelReconnect(id);
    for (const link of [...this.#links.values()]) {
      if ((link.phase.kind === "established" && link.phase.contactID === id) || link.expected === id) this.#drop(link, "local");
    }
    if (reason === "removed") {
      this.#devices.delete(id);
      this.#manuallyDisconnected.delete(id);
    }
    this.parkUnconfirmedMessages(id);
  }

  protected afterUnblocked(id: ContactID): void {
    if (!this.#linkTo(id) && !this.#manuallyDisconnected.has(id)) this.#startReconnect(id);
  }

  // MARK: Re-linking within this tab

  /** A few quick attempts on the same phone, no click needed; then the contact shows as out of range. */
  #scheduleReconnect(id: ContactID): void {
    const contact = this.contact(id);
    if (!contact || contact.isBlocked || this.#manuallyDisconnected.has(id) || !this.#devices.has(id)) {
      this.#cancelReconnect(id);
      return;
    }
    const state = this.#reconnects.get(id) ?? { attempt: 0, timer: null };
    this.#reconnects.set(id, state);
    if (state.timer) return;
    const delay = this.#config.reconnectDelaysMs[state.attempt];
    if (delay === undefined) {
      debug("link", "giving up re-linking", { attempts: state.attempt });
      this.#reconnects.delete(id);
      return;
    }
    state.attempt += 1;
    state.timer = setTimeout(() => {
      state.timer = null;
      if (this.#reconnects.get(id) !== state) return;
      void this.#reconnectNow(id);
    }, delay);
  }

  #startReconnect(id: ContactID): void {
    if (!this.#devices.has(id)) return;
    this.#cancelReconnect(id);
    this.#scheduleReconnectImmediately(id);
  }

  #scheduleReconnectImmediately(id: ContactID): void {
    this.#reconnects.set(id, { attempt: 0, timer: null });
    void this.#reconnectNow(id);
  }

  #cancelReconnect(id: ContactID): void {
    const state = this.#reconnects.get(id);
    if (state?.timer) clearTimeout(state.timer);
    this.#reconnects.delete(id);
  }

  async #reconnectNow(id: ContactID): Promise<void> {
    const device = this.#devices.get(id);
    const contact = this.contact(id);
    if (!device || !contact || contact.isBlocked || this.#linkTo(id) || this.#links.has(device.token)) return;
    const link = this.#newLink(device, id, false);
    this.changed();
    const opened = await this.#open(link);
    if (opened !== "ok") {
      this.#linkEnded(link, "connectionLost");
      this.changed();
      return;
    }
    if (this.#recognise(link.beacon!)?.id !== id) {
      // A different phone answered on this device: do not reveal anything to it.
      this.#links.delete(link.token);
      this.#clearTimers(link);
      this.#closeQuietly(link);
      this.#cancelReconnect(id);
      this.changed();
      return;
    }
    this.#invite(link);
    this.changed();
  }

  // MARK: Erasing

  async eraseEverything(): Promise<void> {
    await this.ready();
    for (const id of this.contacts.map((c) => c.id)) this.disconnect(id);
    for (const link of [...this.#links.values()]) this.#drop(link, "local");
    for (const id of [...this.#reconnects.keys()]) this.#cancelReconnect(id);
    this.#devices.clear();
    this.#manuallyDisconnected.clear();
    this.resetState();
    this.#identity = newIdentity();
    this.#queuedSaves.clear();
    const seed = this.#identity.seed;
    await this.#write(async () => {
      await this.#storage.eraseAll();
      await this.#storage.saveIdentity(seed);
    });
    this.changed();
  }

  // MARK: Storage (one queue, so writes land in order)

  #write(operation: () => Promise<void>): Promise<boolean> {
    const result = this.#storageChain.then(operation).then(
      () => true,
      (error: unknown) => {
        debug("storage", "write failed", { error: errorKind(error) });
        return false;
      },
    );
    this.#storageChain = result;
    return result;
  }

  protected persistConversation(id: ContactID): Promise<boolean> {
    // A save already waiting in the queue will store the newest state when it runs.
    const queued = this.#queuedSaves.get(id);
    if (queued) return queued;
    const promise = this.#write(async () => {
      this.#queuedSaves.delete(id);
      const conversation = this.conversations.get(id);
      if (!conversation) return;
      await this.#storage.saveConversation(id, conversation);
    });
    this.#queuedSaves.set(id, promise);
    return promise;
  }

  protected persistContacts(): void {
    const contacts = this.contacts;
    void this.#write(() => this.#storage.saveContacts(contacts));
  }

  protected persistProfile(): void {
    const profile = this.profile;
    void this.#write(() => this.#storage.saveProfile(profile));
  }

  protected deleteStoredConversation(id: ContactID): void {
    void this.#write(() => this.#storage.deleteConversation(id));
  }

  /** Resolves once every queued storage write has finished. For tests. */
  async flushStorage(): Promise<void> {
    await this.#storageChain;
  }

  // MARK: Timers

  /** Runs `action` after `ms`, but only if this link is still the current one. */
  #after(link: Link, ms: number, action: () => void): void {
    const timer = setTimeout(() => {
      link.timers = link.timers.filter((t) => t !== timer);
      if (this.#links.get(link.token) === link) action();
    }, ms);
    link.timers.push(timer);
  }

  #clearTimers(link: Link): void {
    link.timers.forEach(clearTimeout);
    link.timers = [];
  }
}
