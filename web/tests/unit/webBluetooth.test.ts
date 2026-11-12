/**
 * WebBluetoothTransport against a scripted stand-in for `navigator.bluetooth`.
 * This checks our use of the API (order of calls, error mapping, event wiring). It cannot prove
 * that Chrome and an iPhone talk to each other; that needs a person and real hardware.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { BEACON_UUID, INBOX_UUID, OUTBOX_UUID, SERVICE_UUID } from "../../src/engine/transport";
import { WebBluetoothTransport } from "../../src/engine/webBluetooth";

class FakeTarget {
  #listeners = new Map<string, Set<(e: Event) => void>>();
  addEventListener(type: string, fn: (e: Event) => void) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, new Set());
    this.#listeners.get(type)!.add(fn);
  }
  removeEventListener(type: string, fn: (e: Event) => void) {
    this.#listeners.get(type)?.delete(fn);
  }
  dispatch(type: string, target: unknown = this) {
    for (const fn of [...(this.#listeners.get(type) ?? [])]) fn({ target } as unknown as Event);
  }
  count(type: string) {
    return this.#listeners.get(type)?.size ?? 0;
  }
}

function fakeBluetooth(options: { hasService?: boolean; available?: boolean; neverConnects?: boolean } = {}) {
  const calls: string[] = [];
  const writes: Uint8Array[] = [];
  const outbox = Object.assign(new FakeTarget(), {
    value: null as DataView | null,
    async startNotifications() {
      calls.push("startNotifications");
      return outbox;
    },
  });
  const beacon = {
    async readValue() {
      calls.push("readBeacon");
      const bytes = new Uint8Array([9, 1, 2, 3, 4]);
      return new DataView(bytes.buffer, 1, 4); // a view with an offset, as Chrome may return
    },
  };
  const inbox = {
    async writeValueWithResponse(value: Uint8Array) {
      calls.push("write");
      writes.push(new Uint8Array(value));
    },
  };
  const service = {
    async getCharacteristic(uuid: string) {
      calls.push(`char:${uuid.slice(4, 8)}`);
      if (uuid === BEACON_UUID) return beacon;
      if (uuid === INBOX_UUID) return inbox;
      if (uuid === OUTBOX_UUID) return outbox;
      throw new Error("unknown");
    },
  };
  const gatt = {
    connected: false,
    connect() {
      calls.push("connect");
      if (options.neverConnects) return new Promise(() => {});
      gatt.connected = true;
      return Promise.resolve(server);
    },
    disconnect() {
      calls.push("disconnect");
      gatt.connected = false;
    },
  };
  const server = {
    async getPrimaryService(uuid: string) {
      calls.push("service");
      expect(uuid).toBe(SERVICE_UUID);
      if (options.hasService === false) throw Object.assign(new Error("no service"), { name: "NotFoundError" });
      return service;
    },
  };
  const device = Object.assign(new FakeTarget(), { id: "dev-1", gatt });
  let cancel = false;
  const bluetooth = Object.assign(new FakeTarget(), {
    async getAvailability() {
      return options.available ?? true;
    },
    async requestDevice(request: RequestDeviceOptions) {
      calls.push("requestDevice");
      expect(request).toEqual({ filters: [{ services: [SERVICE_UUID] }] });
      if (cancel) throw Object.assign(new Error("User cancelled"), { name: "NotFoundError" });
      return device;
    },
  });
  vi.stubGlobal("navigator", { bluetooth, userAgent: "Mozilla/5.0 Chrome/140.0" });
  return {
    calls,
    writes,
    outbox,
    device,
    gatt,
    bluetooth,
    cancelNext() {
      cancel = true;
    },
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("WebBluetoothTransport", () => {
  it("reports availability", async () => {
    vi.stubGlobal("navigator", { userAgent: "Mozilla/5.0 Chrome/140.0" });
    vi.stubGlobal("isSecureContext", false);
    expect(await new WebBluetoothTransport().availability()).toBe("insecure");
    vi.stubGlobal("isSecureContext", true);
    expect(await new WebBluetoothTransport().availability()).toBe("unsupported");
    vi.stubGlobal("navigator", { userAgent: "Mozilla/5.0 Firefox/140.0" });
    vi.stubGlobal("isSecureContext", false);
    expect(await new WebBluetoothTransport().availability()).toBe("unsupported");
    fakeBluetooth({ available: false });
    expect(await new WebBluetoothTransport().availability()).toBe("bluetoothOff");
    fakeBluetooth();
    expect(await new WebBluetoothTransport().availability()).toBe("ready");
  });

  it("subscribes before reading the beacon, copies values, and writes with response", async () => {
    const fake = fakeBluetooth();
    const transport = new WebBluetoothTransport();
    const choice = await transport.choose();
    if (choice.kind !== "picked") throw new Error("expected a device");
    const notified: Uint8Array[] = [];
    let dropped = 0;
    const connection = await choice.device.connect({ onNotify: (c) => notified.push(c), onDisconnected: () => dropped++ });
    expect(fake.calls).toEqual(["requestDevice", "connect", "service", "char:0002", "char:0003", "char:0004", "startNotifications", "readBeacon"]);
    expect(connection.beacon).toEqual(new Uint8Array([1, 2, 3, 4]));

    const bytes = new Uint8Array([0, 1, 1, 7, 7]);
    fake.outbox.value = new DataView(bytes.buffer, 1, 3);
    fake.outbox.dispatch("characteristicvaluechanged");
    expect(notified).toEqual([new Uint8Array([1, 1, 7])]);

    await connection.write(new Uint8Array([1, 5]));
    expect(fake.writes).toEqual([new Uint8Array([1, 5])]);

    // Picking the same phone again gives the same token.
    const again = await transport.choose();
    expect(again.kind === "picked" && again.device.token).toBe(choice.device.token);

    fake.device.dispatch("gattserverdisconnected");
    expect(dropped).toBe(1);
    await expect(connection.write(new Uint8Array([1]))).rejects.toThrow();
    expect(fake.device.count("gattserverdisconnected")).toBe(0);
    expect(fake.outbox.count("characteristicvaluechanged")).toBe(0);
  });

  it("a local disconnect does not report a drop", async () => {
    const fake = fakeBluetooth();
    const choice = await new WebBluetoothTransport().choose();
    if (choice.kind !== "picked") throw new Error("expected a device");
    let dropped = 0;
    const connection = await choice.device.connect({ onNotify() {}, onDisconnected: () => dropped++ });
    connection.disconnect();
    fake.device.dispatch("gattserverdisconnected");
    expect(dropped).toBe(0);
    expect(fake.calls.at(-1)).toBe("disconnect");
  });

  it("maps a cancelled chooser, a missing service and a connect timeout", async () => {
    const fake = fakeBluetooth({ hasService: false });
    const transport = new WebBluetoothTransport();
    const choice = await transport.choose();
    if (choice.kind !== "picked") throw new Error("expected a device");
    await expect(choice.device.connect({ onNotify() {}, onDisconnected() {} })).rejects.toMatchObject({ reason: "notEarshot" });
    expect(fake.gatt.connected).toBe(false);
    fake.cancelNext();
    expect(await transport.choose()).toEqual({ kind: "cancelled" });

    vi.useFakeTimers();
    const slow = fakeBluetooth({ neverConnects: true });
    const picked = await new WebBluetoothTransport().choose();
    if (picked.kind !== "picked") throw new Error("expected a device");
    const attempt = picked.device.connect({ onNotify() {}, onDisconnected() {} }).catch((e: { reason?: string }) => e.reason);
    await vi.advanceTimersByTimeAsync(15_001);
    expect(await attempt).toBe("unreachable");
    expect(slow.calls).toContain("disconnect");
  });
});
