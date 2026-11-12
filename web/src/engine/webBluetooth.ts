/**
 * The real radio: Web Bluetooth in Chromium browsers (desktop Chrome/Edge, Android Chrome),
 * on https or localhost only. Safari, Firefox and every iPhone browser have no Web Bluetooth.
 *
 * What the platform allows, and how this file deals with it:
 * - The browser can only be the central. It cannot announce itself, so it never receives a request.
 * - `requestDevice` shows the browser's own chooser and needs a click. An iPhone with Earshot in
 *   the background usually does not appear there (iOS hides the service UUID), so the person must
 *   open Earshot on the phone first. A link that is already open survives the phone locking.
 * - Re-connecting to the same `BluetoothDevice` object later in the same tab
 *   (`device.gatt.connect()`) needs no click. The engine uses that to re-link after a drop.
 * - There is no access to the packet size (MTU), so chunks are kept small (see FramedLink).
 */
import type { Availability, PeerToken } from "./api";
import { debug, errorKind } from "./log";
import {
  BEACON_UUID,
  ConnectError,
  INBOX_UUID,
  OUTBOX_UUID,
  SERVICE_UUID,
  type ChooseResult,
  type Device,
  type GattConnection,
  type GattHandlers,
  type Transport,
} from "./transport";

/** How long a Bluetooth connection attempt may take before it counts as "out of range". */
const CONNECT_TIMEOUT_MS = 15_000;

function bluetooth(): Bluetooth | null {
  if (typeof navigator === "undefined") return null;
  return (navigator as Navigator & { bluetooth?: Bluetooth }).bluetooth ?? null;
}

function looksLikeChromium(): boolean {
  return typeof navigator !== "undefined" && /\b(Chrome|Chromium)\//.test(navigator.userAgent);
}

export function webBluetoothAvailable(): boolean {
  return bluetooth() !== null;
}

function withTimeout<T>(promise: Promise<T>, ms: number, onTimeout: () => void): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      onTimeout();
      reject(new ConnectError("unreachable"));
    }, ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

export class WebBluetoothTransport implements Transport {
  /** One Device per BluetoothDevice, so picking the same phone again gives the same token. */
  #devices = new Map<string, WebBluetoothDevice>();
  #serial = 0;

  async availability(): Promise<Availability> {
    const bt = bluetooth();
    if (!bt) {
      // Chrome hides navigator.bluetooth entirely on plain http pages.
      const secure = typeof isSecureContext === "undefined" ? true : isSecureContext;
      return !secure && looksLikeChromium() ? "insecure" : "unsupported";
    }
    try {
      return (await bt.getAvailability()) ? "ready" : "bluetoothOff";
    } catch {
      // Some builds lack getAvailability; requestDevice will tell us.
      return "ready";
    }
  }

  onAvailabilityChanged(listener: (availability: Availability) => void): () => void {
    const bt = bluetooth();
    if (!bt) return () => {};
    const handler = () => {
      void this.availability().then(listener);
    };
    bt.addEventListener("availabilitychanged", handler);
    return () => bt.removeEventListener("availabilitychanged", handler);
  }

  async choose(): Promise<ChooseResult> {
    const bt = bluetooth();
    if (!bt) return { kind: "failed", reason: "unavailable" };
    let picked: BluetoothDevice;
    try {
      picked = await bt.requestDevice({ filters: [{ services: [SERVICE_UUID] }] });
    } catch (error) {
      // Chrome reports both "chooser closed" and "no Bluetooth adapter" as NotFoundError.
      if (errorKind(error) === "NotFoundError" && (await this.availability()) === "ready") return { kind: "cancelled" };
      debug("bluetooth", "requestDevice failed", { error: errorKind(error) });
      return { kind: "failed", reason: "unavailable" };
    }
    let device = this.#devices.get(picked.id);
    if (!device) {
      device = new WebBluetoothDevice(`web#${++this.#serial}`, picked);
      this.#devices.set(picked.id, device);
    }
    return { kind: "picked", device };
  }
}

class WebBluetoothDevice implements Device {
  constructor(
    readonly token: PeerToken,
    private readonly device: BluetoothDevice,
  ) {}

  async connect(handlers: GattHandlers): Promise<GattConnection> {
    const gatt = this.device.gatt;
    if (!gatt) throw new ConnectError("notEarshot");
    // Everything below belongs to this one connection; events from an older one are ignored.
    let alive = true;
    let outbox: BluetoothRemoteGATTCharacteristic | null = null;

    const onValue = (event: Event) => {
      if (!alive) return;
      const value = (event.target as BluetoothRemoteGATTCharacteristic | null)?.value;
      // Copy: Chrome may reuse the DataView's buffer for the next notification.
      if (value) handlers.onNotify(new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)));
    };
    const cleanUp = () => {
      this.device.removeEventListener("gattserverdisconnected", onDisconnected);
      outbox?.removeEventListener("characteristicvaluechanged", onValue);
    };
    const onDisconnected = () => {
      if (!alive) return;
      alive = false;
      cleanUp();
      handlers.onDisconnected();
    };
    const close = () => {
      if (!alive) return;
      alive = false;
      cleanUp();
      try {
        gatt.disconnect();
      } catch {
        // Already gone.
      }
    };

    this.device.addEventListener("gattserverdisconnected", onDisconnected);
    try {
      const server = await withTimeout(gatt.connect(), CONNECT_TIMEOUT_MS, () => {
        try {
          gatt.disconnect();
        } catch {
          // ignore
        }
      });
      let beacon: BluetoothRemoteGATTCharacteristic;
      let inbox: BluetoothRemoteGATTCharacteristic;
      try {
        const service = await server.getPrimaryService(SERVICE_UUID);
        beacon = await service.getCharacteristic(BEACON_UUID);
        inbox = await service.getCharacteristic(INBOX_UUID);
        outbox = await service.getCharacteristic(OUTBOX_UUID);
      } catch (error) {
        if (!alive || errorKind(error) === "NetworkError") throw new ConnectError("unreachable");
        throw new ConnectError("notEarshot");
      }
      // Listen first: the phone refuses writes from a browser that is not subscribed.
      outbox.addEventListener("characteristicvaluechanged", onValue);
      await outbox.startNotifications();
      const value = await beacon.readValue();
      if (!alive) throw new ConnectError("unreachable");
      const write = (piece: Uint8Array): Promise<void> => {
        if (!alive) return Promise.reject(new Error("disconnected"));
        const copy = new Uint8Array(piece);
        return typeof inbox.writeValueWithResponse === "function" ? inbox.writeValueWithResponse(copy) : inbox.writeValue(copy);
      };
      return {
        beacon: new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)),
        write,
        disconnect: close,
      };
    } catch (error) {
      debug("bluetooth", "connect failed", { error: errorKind(error) });
      close();
      throw error instanceof ConnectError ? error : new ConnectError("unreachable");
    }
  }
}
