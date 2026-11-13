/**
 * A pretend iPhone for the engine's unit tests: the invitee half of Messenger.swift, written
 * with the engine's own crypto and wire modules. It sits behind a MemoryDevice, so the engine
 * talks to it through exactly the same chunked Bluetooth frames it would send to a real phone.
 *
 * The live interop test (live.test.ts) replaces this with the real Swift Messenger.
 */
import { bytesEqual, randomBytes, randomUUID } from "../../../src/engine/bytes";
import {
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
} from "../../../src/engine/crypto";
import { MemoryDevice, type FakePeripheral, type PeripheralLink } from "../../../src/engine/memoryTransport";
import { ConnectError } from "../../../src/engine/transport";
import {
  FrameKind,
  MAX_BT_FRAME_LENGTH,
  MAX_UNLINKED_FRAME_LENGTH,
  Reassembler,
  chunk,
  decodeFrame,
  decodeInviteContext,
  decodePayload,
  encodeBeacon,
  encodeBtFrame,
  encodeHello,
  encodePayload,
  encodeSealed,
  parseBtFrame,
  parseInviteBody,
  type InviteContext,
  type Payload,
} from "../../../src/engine/wire";

export interface FakePhoneOptions {
  name?: string;
  seed?: Uint8Array;
  /** Accept requests from new people automatically. Default true. */
  autoAccept?: boolean;
  /** Send receipts for messages. Default true. */
  ack?: boolean;
  /** Reply "Echo: <text>" to each message. Default false. */
  echo?: boolean;
  /** Notification chunk size. Default 20 (the smallest Bluetooth packet), to exercise chunking. */
  notifyChunk?: number;
}

interface PhoneLink {
  phase: "awaitingHello" | "awaitingAuth" | "established";
  handshake: Handshake;
  channel: SecureChannel | null;
  localEphemeral: Uint8Array;
  remoteEphemeral: Uint8Array | null;
  expected: string | null;
  authSent: boolean;
  peerKey: Uint8Array | null;
}

export class FakePhone implements FakePeripheral {
  readonly identity: Identity;
  name: string;
  nonce = randomBytes(8);
  options: Required<Omit<FakePhoneOptions, "seed" | "name">>;
  /** Saved contacts on the phone, by contact ID. */
  readonly contacts = new Map<string, { key: Uint8Array; name: string; blocked: boolean }>();
  readonly device: MemoryDevice;

  // What the phone saw, for assertions.
  readonly invites: InviteContext[] = [];
  readonly payloads: Payload[] = [];
  readonly texts: string[] = [];
  readonly frameKinds: number[] = [];
  connections = 0;

  /** False makes connecting fail as if the phone were out of range. */
  inRange = true;
  /** Set to make the browser's connection read a broken beacon. */
  beaconOverride: Uint8Array | null = null;
  /** Writes longer than this are refused (simulates a phone without the long-write fix and a small MTU). */
  maxWriteLength = Infinity;

  #peripheral: PeripheralLink | null = null;
  #reassembler = new Reassembler();
  #pendingInvite = false;
  #link: PhoneLink | null = null;

  constructor(token: string, options: FakePhoneOptions = {}) {
    this.identity = options.seed ? identityFromSeed(options.seed) : newIdentity();
    this.name = options.name ?? "Jensen Huang";
    this.options = { autoAccept: options.autoAccept ?? true, ack: options.ack ?? true, echo: options.echo ?? false, notifyChunk: options.notifyChunk ?? 20 };
    this.device = new MemoryDevice(token, this);
  }

  get contactID(): string {
    return contactIDFor(this.identity.publicKey);
  }

  get isLinked(): boolean {
    return this.#link?.phase === "established";
  }

  get hasPendingInvite(): boolean {
    return this.#pendingInvite;
  }

  // MARK: FakePeripheral

  connected(link: PeripheralLink): Uint8Array {
    if (!this.inRange) throw new ConnectError("unreachable");
    this.connections += 1;
    this.#peripheral = link;
    this.#reassembler.reset();
    return this.beaconOverride ?? encodeBeacon({ displayName: this.name, nonce: this.nonce, tag: discoveryTag(this.identity.publicKey, this.nonce) });
  }

  write(piece: Uint8Array): void {
    if (piece.length > this.maxWriteLength) throw new Error("NotSupportedError: long write refused");
    const limit = this.#link ? MAX_BT_FRAME_LENGTH : MAX_UNLINKED_FRAME_LENGTH;
    let frame: Uint8Array | null;
    try {
      frame = this.#reassembler.append(piece, limit);
    } catch {
      throw new Error("InvalidAttributeValueLength");
    }
    if (frame) this.#frame(frame);
  }

  disconnected(): void {
    this.#peripheral = null;
    this.#link = null;
    this.#pendingInvite = false;
    this.#reassembler.reset();
  }

  // MARK: Controls for tests

  /** The person taps Accept on a pending request. */
  acceptPending(): void {
    if (!this.#pendingInvite) return;
    this.#pendingInvite = false;
    this.#accept(null);
  }

  declinePending(): void {
    if (!this.#pendingInvite) return;
    this.#pendingInvite = false;
    this.#notify(encodeBtFrame(FrameKind.decline));
  }

  sendText(text: string, id = randomUUID()): string {
    this.#send({ kind: "text", id, text });
    return id;
  }

  sendPayload(payload: Payload): void {
    this.#send(payload);
  }

  /** Sends arbitrary bytes as a Bluetooth data frame (for malformed-input tests). */
  sendData(data: Uint8Array): void {
    this.#notify(encodeBtFrame(FrameKind.data, data));
  }

  /** Sends one raw chunk, marker byte included. */
  sendRawChunk(piece: Uint8Array): void {
    this.#peripheral?.notify(piece);
  }

  /** Seals a payload without sending it, to replay it later. */
  sealForLater(payload: Payload): Uint8Array {
    const link = this.#link!;
    return encodeSealed(link.channel!.seal(encodePayload(payload)));
  }

  /** The Bluetooth connection drops (walked out of range). */
  drop(): void {
    this.#peripheral?.drop();
  }

  /** Earshot restarted on the phone: new session number. */
  restart(): void {
    this.drop();
    this.nonce = randomBytes(8);
  }

  // MARK: Protocol (mirrors Messenger.swift as invitee)

  #frame(frame: Uint8Array): void {
    const parsed = parseBtFrame(frame);
    if (!parsed) return;
    this.frameKinds.push(parsed.kind);
    switch (parsed.kind) {
      case FrameKind.invite:
        this.#invited(parsed.body);
        break;
      case FrameKind.data:
        if (this.#link) this.#data(parsed.body);
        break;
      case FrameKind.close:
        this.#link = null;
        this.#pendingInvite = false;
        break;
      default:
        break;
    }
  }

  #invited(body: Uint8Array): void {
    const invite = parseInviteBody(body);
    const context = invite ? decodeInviteContext(invite.context) : null;
    if (!context || context.v !== 1 || context.nonce.length !== 8) return this.#notify(encodeBtFrame(FrameKind.decline));
    this.invites.push(context);
    if (context.tag) {
      // A reconnection: accepted silently only from a saved, unblocked contact.
      const known = [...this.contacts.entries()].find(([, c]) =>
        bytesEqual(pairTag(this.identity.publicKey, c.key, context.nonce, this.nonce), context.tag!),
      );
      if (!known || known[1].blocked) return this.#notify(encodeBtFrame(FrameKind.decline));
      this.#accept(known[0]);
      return;
    }
    if (!context.name) return this.#notify(encodeBtFrame(FrameKind.decline));
    if (this.options.autoAccept) queueMicrotask(() => this.#accept(null));
    else this.#pendingInvite = true;
  }

  #accept(expected: string | null): void {
    const handshake = new Handshake();
    this.#link = {
      phase: "awaitingHello",
      handshake,
      channel: null,
      localEphemeral: handshake.publicKey,
      remoteEphemeral: null,
      expected,
      authSent: false,
      peerKey: null,
    };
    this.#notify(encodeBtFrame(FrameKind.accept));
    this.#notify(encodeBtFrame(FrameKind.data, encodeHello(1, handshake.publicKey)));
  }

  #data(data: Uint8Array): void {
    const link = this.#link!;
    try {
      const frame = decodeFrame(data);
      if (frame.kind === "hello") {
        if (link.phase !== "awaitingHello") throw new Error("unexpected hello");
        link.channel = link.handshake.channel(frame.ephemeralKey);
        link.remoteEphemeral = frame.ephemeralKey;
        link.phase = "awaitingAuth";
        const contact = link.expected ? this.contacts.get(link.expected) : undefined;
        if (contact) this.#send({ kind: "knock", knock: knock(this.identity.publicKey, contact.key, link.localEphemeral, frame.ephemeralKey) });
        else this.#sendAuth();
        return;
      }
      const payload = decodePayload(link.channel!.open(frame.box));
      this.payloads.push(payload);
      this.#payload(payload);
    } catch {
      this.#close();
    }
  }

  #payload(payload: Payload): void {
    const link = this.#link!;
    if (payload.kind === "knock" && link.phase === "awaitingAuth") {
      const contact = link.expected ? this.contacts.get(link.expected) : undefined;
      if (link.authSent || !contact) return;
      const valid = knock(this.identity.publicKey, contact.key, link.remoteEphemeral!, link.localEphemeral);
      if (!bytesEqual(valid, payload.knock)) throw new Error("bad knock");
      this.#sendAuth();
    } else if (payload.kind === "auth" && link.phase === "awaitingAuth") {
      const transcript = handshakeTranscript(link.remoteEphemeral!, link.localEphemeral);
      if (!verifySignature(payload.signature, transcript, payload.identityKey)) throw new Error("bad signature");
      const id = contactIDFor(payload.identityKey);
      if (link.expected && link.expected !== id) throw new Error("wrong contact");
      const existing = this.contacts.get(id);
      if (existing?.blocked) throw new Error("blocked");
      this.contacts.set(id, { key: payload.identityKey, name: payload.name, blocked: false });
      if (!link.authSent) this.#sendAuth();
      link.peerKey = payload.identityKey;
      link.phase = "established";
    } else if (payload.kind === "text" && link.phase === "established") {
      this.texts.push(payload.text);
      if (this.options.ack) this.#send({ kind: "ack", id: payload.id });
      if (this.options.echo) this.#send({ kind: "text", id: randomUUID(), text: `Echo: ${payload.text}` });
    } else if (payload.kind === "ack" && link.phase === "established") {
      // recorded in `payloads`
    } else if (payload.kind === "bye" && link.phase === "established") {
      this.#close();
    } else {
      throw new Error("protocol violation");
    }
  }

  #sendAuth(): void {
    const link = this.#link!;
    link.authSent = true;
    this.#send({
      kind: "auth",
      identityKey: this.identity.publicKey,
      name: this.name,
      signature: sign(this.identity, handshakeTranscript(link.localEphemeral, link.remoteEphemeral!)),
    });
  }

  #send(payload: Payload): void {
    const link = this.#link;
    if (!link?.channel) return;
    this.#notify(encodeBtFrame(FrameKind.data, encodeSealed(link.channel.seal(encodePayload(payload)))));
  }

  /** The phone ends the link (like `drop` → `transport.disconnect` → close frame on iOS). */
  #close(): void {
    this.#link = null;
    this.#notify(encodeBtFrame(FrameKind.close));
  }

  #notify(frame: Uint8Array): void {
    if (!this.#peripheral) return;
    for (const piece of chunk(frame, this.options.notifyChunk)) this.#peripheral.notify(piece);
  }
}
