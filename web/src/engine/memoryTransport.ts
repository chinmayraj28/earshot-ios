/**
 * An in-memory stand-in for Web Bluetooth, used by the unit tests and by the live interop
 * test (where the "phone" is the real Swift Messenger behind a pipe).
 *
 * A `MemoryDevice` connects to a `FakePeripheral`: the phone side, which supplies the beacon,
 * receives every chunk the browser writes and can push notifications back through `PeripheralLink`.
 * Deliveries are asynchronous (microtasks or real I/O), like the real radio.
 */
import type { Availability, PeerToken } from "./api";
import { ConnectError, type ChooseResult, type Device, type GattConnection, type GattHandlers, type Transport } from "./transport";

/** What the phone side can do to the browser on one open connection. */
export interface PeripheralLink {
  /** Sends one chunk to the browser (a notification on the outbox). */
  notify(chunk: Uint8Array): void;
  /** The phone drops the Bluetooth connection (walked away, switched off). */
  drop(): void;
}

/** The phone side of a fake connection. */
export interface FakePeripheral {
  /**
   * The browser connected and subscribed. Return the beacon bytes, or throw
   * `ConnectError` to simulate "not an Earshot phone" or "out of range".
   */
  connected(link: PeripheralLink): Promise<Uint8Array> | Uint8Array;
  /** One chunk written by the browser. Throw (or reject) to refuse the write. */
  write(chunk: Uint8Array): Promise<void> | void;
  /** The browser closed the connection. */
  disconnected(): void;
}

export class MemoryDevice implements Device {
  /** Writes seen by the phone side, for tests that count chunks. */
  readonly written: Uint8Array[] = [];
  #current: { handlers: GattHandlers; alive: boolean } | null = null;

  constructor(
    readonly token: PeerToken,
    readonly peripheral: FakePeripheral,
  ) {}

  get isConnected(): boolean {
    return this.#current?.alive === true;
  }

  async connect(handlers: GattHandlers): Promise<GattConnection> {
    const session = { handlers, alive: true };
    this.#current = session;
    const link: PeripheralLink = {
      notify: (chunk) => {
        const copy = chunk.slice();
        queueMicrotask(() => {
          if (session.alive) handlers.onNotify(copy);
        });
      },
      drop: () => {
        if (!session.alive) return;
        session.alive = false;
        queueMicrotask(() => handlers.onDisconnected());
        this.peripheral.disconnected();
      },
    };
    let beacon: Uint8Array;
    try {
      beacon = await this.peripheral.connected(link);
    } catch (error) {
      session.alive = false;
      throw error instanceof ConnectError ? error : new ConnectError("unreachable");
    }
    return {
      beacon,
      write: async (chunk) => {
        if (!session.alive) throw new Error("disconnected");
        this.written.push(chunk.slice());
        await this.peripheral.write(chunk.slice());
        if (!session.alive) throw new Error("disconnected");
      },
      disconnect: () => {
        if (!session.alive) return;
        session.alive = false;
        this.peripheral.disconnected();
      },
    };
  }
}

export class MemoryTransport implements Transport {
  #availability: Availability = "ready";
  #listeners = new Set<(availability: Availability) => void>();
  /** What the next `choose()` calls return, in order. Empty means "cancelled". Any Device works. */
  readonly choices: Array<Device | "cancel"> = [];

  async availability(): Promise<Availability> {
    return this.#availability;
  }

  setAvailability(availability: Availability): void {
    this.#availability = availability;
    for (const listener of this.#listeners) listener(availability);
  }

  onAvailabilityChanged(listener: (availability: Availability) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  async choose(): Promise<ChooseResult> {
    if (this.#availability !== "ready") return { kind: "failed", reason: "unavailable" };
    const next = this.choices.shift();
    if (!next || next === "cancel") return { kind: "cancelled" };
    return { kind: "picked", device: next };
  }
}
