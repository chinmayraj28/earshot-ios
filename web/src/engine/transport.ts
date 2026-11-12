/**
 * The radio abstraction the engine uses, and the framing that sits on top of it.
 *
 * The browser is always the Bluetooth "central": it connects to a phone, subscribes to the
 * phone's outbox characteristic (the phone refuses writes from anyone who is not listening),
 * reads the beacon, then writes chunked frames into the inbox and receives chunked
 * notifications from the outbox.
 *
 *   Transport      picks a device (the browser's chooser) and reports Bluetooth availability.
 *   Device         one phone picked in this session; `connect()` opens a GattConnection.
 *   GattConnection the raw Bluetooth operations on one open connection.
 *   FramedLink     turns a GattConnection into whole frames: one write queue, chunking,
 *                  reassembly with size limits. Shared by the real and fake transports.
 */
import type { Availability, PeerToken } from "./api";
import { debug, errorKind } from "./log";
import { MAX_BT_FRAME_LENGTH, Reassembler, encodeBtFrame, parseBtFrame, type FrameKind } from "./wire";

export const SERVICE_UUID = "8e5c0001-6f1a-4c3b-9d2e-ea25407a11e0";
export const BEACON_UUID = "8e5c0002-6f1a-4c3b-9d2e-ea25407a11e0";
/** Written by the browser (write with response). */
export const INBOX_UUID = "8e5c0003-6f1a-4c3b-9d2e-ea25407a11e0";
/** Notified to the browser. */
export const OUTBOX_UUID = "8e5c0004-6f1a-4c3b-9d2e-ea25407a11e0";

/**
 * Default chunk size, marker byte included. Small enough to fit in one Bluetooth packet on
 * the usual iPhone connection (MTU 185 => 182 bytes per write), so the phone never sees a
 * "long write", which phones without the long-write fix refuse.
 */
export const DEFAULT_CHUNK_LENGTH = 180;
/** Fallback after a refused write: fits even the smallest Bluetooth packet (MTU 23 => 20 bytes). */
export const MIN_CHUNK_LENGTH = 20;

export type ChooseResult =
  | { kind: "picked"; device: Device }
  | { kind: "cancelled" }
  | { kind: "failed"; reason: "unavailable" };

export interface Transport {
  availability(): Promise<Availability>;
  /** Calls `listener` when Bluetooth is switched on or off. Returns an unsubscribe function. */
  onAvailabilityChanged(listener: (availability: Availability) => void): () => void;
  /** Opens the device chooser. Must be called from a click handler in a real browser. */
  choose(): Promise<ChooseResult>;
}

export class ConnectError extends Error {
  constructor(readonly reason: "notEarshot" | "unreachable") {
    super(reason);
  }
}

export interface GattHandlers {
  /** One chunk from the phone's outbox. */
  onNotify(chunk: Uint8Array): void;
  /** The Bluetooth connection dropped (out of range, phone switched off, ...). Not called after `disconnect()`. */
  onDisconnected(): void;
}

export interface Device {
  /** Stable for this device during this page session. */
  readonly token: PeerToken;
  /**
   * Connects, finds the Earshot service, subscribes to the outbox FIRST, then reads the beacon.
   * Throws `ConnectError`. Needs no click: only `Transport.choose()` does.
   */
  connect(handlers: GattHandlers): Promise<GattConnection>;
}

export interface GattConnection {
  readonly beacon: Uint8Array;
  /** One write with response. Rejects if the phone refuses it or the connection is gone. */
  write(chunk: Uint8Array): Promise<void>;
  /** Closes the Bluetooth connection. Safe to call more than once. */
  disconnect(): void;
}

export interface FramedLinkHandlers {
  onFrame(kind: FrameKind, body: Uint8Array): void;
  /** The connection is unusable: it dropped, a write failed, or the phone sent malformed chunks. */
  onFailed(reason: "disconnected" | "writeFailed" | "malformed"): void;
}

interface PendingFrame {
  frame: Uint8Array;
  /** How many bytes of `frame` the phone has already accepted. */
  sent: number;
  resolve(): void;
  reject(error: unknown): void;
}

/**
 * Whole frames over one GattConnection.
 *
 * Writes go through ONE queue, one chunk at a time, each confirmed before the next: Web Bluetooth
 * throws "GATT operation already in progress" otherwise, and the phone must receive the chunks of
 * one frame back to back. Example: sending a 400-byte frame with 180-byte chunks writes 3 chunks
 * (179 + 179 + 42 data bytes), and a second frame queued meanwhile waits until those are done.
 *
 * If a write is refused, the link retries the rest of that frame once with 20-byte chunks: a phone
 * without the long-write fix refuses chunks bigger than one packet, and a refused write is not
 * applied on the phone, so continuing with smaller chunks is safe.
 */
export class FramedLink {
  #connection: GattConnection | null = null;
  #handlers: FramedLinkHandlers;
  #queue: PendingFrame[] = [];
  #pumping = false;
  #closed = false;
  #chunkLength: number;
  #fellBack = false;
  #reassembler = new Reassembler();

  constructor(handlers: FramedLinkHandlers, chunkLength = DEFAULT_CHUNK_LENGTH) {
    this.#handlers = handlers;
    this.#chunkLength = Math.max(chunkLength, MIN_CHUNK_LENGTH);
  }

  /** The GattHandlers to pass to `Device.connect`. */
  get gattHandlers(): GattHandlers {
    return {
      onNotify: (piece) => this.#received(piece),
      onDisconnected: () => this.#fail("disconnected"),
    };
  }

  attach(connection: GattConnection): void {
    this.#connection = connection;
    if (this.#closed) connection.disconnect();
    else void this.#pump();
  }

  get isClosed(): boolean {
    return this.#closed;
  }

  get chunkLength(): number {
    return this.#chunkLength;
  }

  /** Queues a frame. Resolves once the phone accepted its last chunk. Never throws synchronously. */
  send(kind: FrameKind, body?: Uint8Array): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("link closed"));
    return new Promise<void>((resolve, reject) => {
      this.#queue.push({ frame: encodeBtFrame(kind, body), sent: 0, resolve, reject });
      void this.#pump();
    });
  }

  /** Closes locally without reporting `onFailed`. Pending frames are rejected. */
  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#rejectAll(new Error("link closed"));
    this.#connection?.disconnect();
  }

  #received(piece: Uint8Array): void {
    if (this.#closed) return;
    let frame: Uint8Array | null;
    try {
      frame = this.#reassembler.append(piece, MAX_BT_FRAME_LENGTH);
    } catch {
      this.#fail("malformed");
      return;
    }
    if (!frame) return;
    const parsed = parseBtFrame(frame);
    // Unknown frame kinds are ignored, as the phone does.
    if (parsed) this.#handlers.onFrame(parsed.kind, parsed.body);
  }

  async #pump(): Promise<void> {
    if (this.#pumping || !this.#connection) return;
    this.#pumping = true;
    try {
      while (!this.#closed && this.#queue.length > 0) {
        const job = this.#queue[0]!;
        // The next chunk only (same cut points as `chunk()`, without cutting the whole frame again).
        const carried = Math.min(this.#chunkLength - 1, job.frame.length - job.sent);
        const piece = new Uint8Array(carried + 1);
        piece[0] = job.sent + carried === job.frame.length ? 1 : 0;
        piece.set(job.frame.subarray(job.sent, job.sent + carried), 1);
        try {
          await this.#connection.write(piece);
        } catch (error) {
          if (this.#closed) return;
          if (!this.#fellBack && this.#chunkLength > MIN_CHUNK_LENGTH) {
            debug("link", "write refused, retrying with small chunks", { error: errorKind(error) });
            this.#fellBack = true;
            this.#chunkLength = MIN_CHUNK_LENGTH;
            continue;
          }
          debug("link", "write failed", { error: errorKind(error) });
          this.#fail("writeFailed");
          return;
        }
        job.sent += carried;
        if (job.sent >= job.frame.length) {
          this.#queue.shift();
          job.resolve();
        }
      }
    } finally {
      this.#pumping = false;
    }
  }

  #rejectAll(error: Error): void {
    const pending = this.#queue;
    this.#queue = [];
    for (const job of pending) job.reject(error);
  }

  #fail(reason: "disconnected" | "writeFailed" | "malformed"): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#rejectAll(new Error(reason));
    this.#connection?.disconnect();
    this.#handlers.onFailed(reason);
  }
}
