/**
 * Every byte format used between the browser and a phone. Mirrors Wire.swift and BluetoothWire.swift.
 *
 * Layers, outermost first, for one message travelling from the browser to a phone:
 *
 * 1. Chunks: Bluetooth moves small pieces, so each frame is cut into chunks whose first byte
 *    says 0 = "more follows" or 1 = "last piece".
 * 2. Bluetooth frame: `[kind][body]`, kind 1 invite, 2 accept, 3 decline, 4 data, 5 close.
 * 3. Engine frame (inside "data"): `[1][version][32-byte key]` hello, or `[2][sealed bytes]`.
 * 4. Payload (inside "sealed", after decryption): JSON exactly as Swift's JSONEncoder writes an
 *    enum with associated values, e.g. `{"ack":{"_0":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"}}`.
 */
import { Limits } from "./api";
import { concatBytes, fromBase64, fromUtf8, normalizeUUID, toBase64, utf8 } from "./bytes";
import { isWellFormed } from "./text";

export class WireError extends Error {}

// MARK: Engine frames (Wire.swift `Frame`)

/** Generous cap; a 2,000 character message is at most ~8 KB of UTF-8. */
export const MAX_FRAME_SIZE = 64 * 1024;

export type Frame = { kind: "hello"; version: number; ephemeralKey: Uint8Array } | { kind: "sealed"; box: Uint8Array };

export function encodeHello(version: number, ephemeralKey: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array([1, version]), ephemeralKey);
}

export function encodeSealed(box: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array([2]), box);
}

export function decodeFrame(data: Uint8Array): Frame {
  const kind = data[0];
  if (kind === undefined || data.length > MAX_FRAME_SIZE) throw new WireError("malformed frame");
  if (kind === 1) {
    if (data.length !== 2 + 32) throw new WireError("malformed hello");
    return { kind: "hello", version: data[1]!, ephemeralKey: data.slice(2) };
  }
  if (kind === 2) return { kind: "sealed", box: data.slice(1) };
  throw new WireError("unknown frame kind");
}

// MARK: Payloads (Wire.swift `Payload`)

export type Payload =
  /** Sent instead of `auth` when reconnecting to a saved contact. */
  | { kind: "knock"; knock: Uint8Array }
  /** Proves who is on the other end. */
  | { kind: "auth"; identityKey: Uint8Array; name: string; signature: Uint8Array }
  | { kind: "text"; id: string; text: string }
  /** Receipt: the message with this id was received and stored. */
  | { kind: "ack"; id: string }
  /** The other side closed the app or switched Earshot off. */
  | { kind: "bye" };

/** JSON in Swift's synthesized Codable shape. Keys inside objects may come in any order; that is fine. */
export function encodePayload(payload: Payload): Uint8Array {
  let value: unknown;
  switch (payload.kind) {
    case "knock":
      value = { knock: { _0: toBase64(payload.knock) } };
      break;
    case "auth":
      value = {
        auth: { _0: { identityKey: toBase64(payload.identityKey), name: payload.name, signature: toBase64(payload.signature) } },
      };
      break;
    case "text":
      value = { text: { _0: { id: payload.id.toUpperCase(), text: payload.text } } };
      break;
    case "ack":
      value = { ack: { _0: payload.id.toUpperCase() } };
      break;
    case "bye":
      value = { bye: {} };
      break;
  }
  return utf8(JSON.stringify(value));
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function needString(value: unknown): string {
  if (typeof value !== "string" || !isWellFormed(value)) throw new WireError("expected a string");
  return value;
}

function needData(value: unknown): Uint8Array {
  const bytes = fromBase64(needString(value));
  if (!bytes) throw new WireError("expected base64");
  return bytes;
}

function needUUID(value: unknown): string {
  const id = normalizeUUID(needString(value));
  if (!id) throw new WireError("expected a UUID");
  return id;
}

/**
 * Parses a payload as strictly as Swift's JSONDecoder: exactly one case key, required fields
 * present with the right types. Throws `WireError` for anything else.
 */
export function decodePayload(data: Uint8Array): Payload {
  const text = fromUtf8(data);
  if (text === null) throw new WireError("payload is not UTF-8");
  let root: unknown;
  try {
    root = JSON.parse(text);
  } catch {
    throw new WireError("payload is not JSON");
  }
  if (!isObject(root)) throw new WireError("payload is not an object");
  const keys = Object.keys(root);
  if (keys.length !== 1) throw new WireError("payload must have exactly one case");
  const kind = keys[0]!;
  const body = root[kind];
  if (!isObject(body)) throw new WireError("payload case must be an object");
  switch (kind) {
    case "knock":
      return { kind: "knock", knock: needData(body._0) };
    case "auth": {
      const auth = body._0;
      if (!isObject(auth)) throw new WireError("auth must be an object");
      return { kind: "auth", identityKey: needData(auth.identityKey), name: needString(auth.name), signature: needData(auth.signature) };
    }
    case "text": {
      const t = body._0;
      if (!isObject(t)) throw new WireError("text must be an object");
      return { kind: "text", id: needUUID(t.id), text: needString(t.text) };
    }
    case "ack":
      return { kind: "ack", id: needUUID(body._0) };
    case "bye":
      return { kind: "bye" };
    default:
      throw new WireError("unknown payload case");
  }
}

// MARK: Invitation context (Wire.swift `InviteContext`)

/**
 * Sent with a connection request. A request from someone new carries `name`; a reconnection
 * from a saved contact carries `tag` (see `pairTag`) and no name.
 */
export interface InviteContext {
  v: number;
  name?: string;
  /** The inviter's session number (8 bytes). */
  nonce: Uint8Array;
  tag?: Uint8Array;
}

export function encodeInviteContext(context: InviteContext): Uint8Array {
  const value: Record<string, unknown> = { v: context.v };
  if (context.name !== undefined) value.name = context.name;
  value.nonce = toBase64(context.nonce);
  if (context.tag !== undefined) value.tag = toBase64(context.tag);
  return utf8(JSON.stringify(value));
}

/** Returns null for anything Swift's `InviteContext.decode` would refuse. Used by test phones. */
export function decodeInviteContext(data: Uint8Array): InviteContext | null {
  if (data.length > 1024) return null;
  try {
    const text = fromUtf8(data);
    if (text === null) return null;
    const root: unknown = JSON.parse(text);
    if (!isObject(root) || typeof root.v !== "number" || !Number.isInteger(root.v)) return null;
    const context: InviteContext = { v: root.v, nonce: needData(root.nonce) };
    if (root.name !== undefined && root.name !== null) context.name = needString(root.name);
    if (root.tag !== undefined && root.tag !== null) context.tag = needData(root.tag);
    return context;
  } catch {
    return null;
  }
}

// MARK: Bluetooth (BluetoothWire.swift)

/** Largest frame a phone may send once linked. */
export const MAX_BT_FRAME_LENGTH = 64 * 1024;
/** Largest frame the phone accepts from a browser before a link exists (the invitation). */
export const MAX_UNLINKED_FRAME_LENGTH = 4 * 1024;
export const BEACON_VERSION = 1;

export const FrameKind = { invite: 1, accept: 2, decline: 3, data: 4, close: 5 } as const;
export type FrameKind = (typeof FrameKind)[keyof typeof FrameKind];

export interface Beacon {
  displayName: string;
  /** The phone's session number; changes every time Earshot starts there. */
  nonce: Uint8Array;
  /** `discoveryTag(phone identity key, nonce)`: lets saved contacts recognise the phone. */
  tag: Uint8Array;
}

/** `[version][nonce length][nonce][tag length][tag][name as UTF-8]`. */
export function encodeBeacon(beacon: Beacon): Uint8Array {
  let name = utf8(beacon.displayName);
  if (name.length > Limits.maxNameBytes) name = name.slice(0, Limits.maxNameBytes);
  return concatBytes(
    new Uint8Array([BEACON_VERSION, Math.min(beacon.nonce.length, 255)]),
    beacon.nonce.slice(0, 255),
    new Uint8Array([Math.min(beacon.tag.length, 255)]),
    beacon.tag.slice(0, 255),
    name,
  );
}

export function parseBeacon(data: Uint8Array): Beacon | null {
  if (data[0] !== BEACON_VERSION) return null;
  let at = 1;
  const take = (): Uint8Array | null => {
    const length = data[at];
    if (length === undefined || data.length - (at + 1) < length) return null;
    const value = data.slice(at + 1, at + 1 + length);
    at += 1 + length;
    return value;
  };
  const nonce = take();
  const tag = take();
  if (!nonce || !tag) return null;
  const rest = data.subarray(at);
  if (rest.length > Limits.maxNameBytes) return null;
  const displayName = fromUtf8(rest);
  if (displayName === null) return null;
  return { displayName, nonce, tag };
}

export function encodeBtFrame(kind: FrameKind, body: Uint8Array = new Uint8Array(0)): Uint8Array {
  return concatBytes(new Uint8Array([kind]), body);
}

export function parseBtFrame(data: Uint8Array): { kind: FrameKind; body: Uint8Array } | null {
  const kind = data[0];
  if (kind === undefined || kind < 1 || kind > 5) return null;
  return { kind: kind as FrameKind, body: data.slice(1) };
}

/** `[nonce length][nonce][context JSON]`. */
export function encodeInviteBody(nonce: Uint8Array, context: Uint8Array): Uint8Array {
  return concatBytes(new Uint8Array([Math.min(nonce.length, 255)]), nonce.slice(0, 255), context);
}

export function parseInviteBody(body: Uint8Array): { nonce: Uint8Array; context: Uint8Array } | null {
  const length = body[0];
  if (length === undefined || body.length - 1 < length) return null;
  return { nonce: body.slice(1, 1 + length), context: body.slice(1 + length) };
}

/** Cuts a frame into chunks of at most `maxChunkLength` bytes, marker byte included. Same cut points as Swift. */
export function chunk(frame: Uint8Array, maxChunkLength: number): Uint8Array[] {
  const payload = Math.max(maxChunkLength - 1, 1);
  const out: Uint8Array[] = [];
  let index = 0;
  do {
    const end = Math.min(index + payload, frame.length);
    const piece = new Uint8Array(end - index + 1);
    piece[0] = end === frame.length ? 1 : 0;
    piece.set(frame.subarray(index, end), 1);
    out.push(piece);
    index = end;
  } while (index < frame.length);
  return out;
}

/** Puts chunks back together. One per direction of a connection. */
export class Reassembler {
  #parts: Uint8Array[] = [];
  #length = 0;

  /** Returns a whole frame once its last chunk arrived, null while more is expected. Throws on bad input. */
  append(piece: Uint8Array, limit: number = MAX_BT_FRAME_LENGTH): Uint8Array | null {
    const marker = piece[0];
    if (marker === undefined || marker > 1) {
      this.reset();
      throw new WireError("malformed chunk");
    }
    this.#parts.push(piece.slice(1));
    this.#length += piece.length - 1;
    if (this.#length > limit) {
      this.reset();
      throw new WireError("frame too long");
    }
    if (marker === 0) return null;
    const frame = concatBytes(...this.#parts);
    this.reset();
    return frame;
  }

  reset(): void {
    this.#parts = [];
    this.#length = 0;
  }
}
