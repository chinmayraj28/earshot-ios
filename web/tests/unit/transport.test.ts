/** FramedLink: the single write queue, chunking, the small-chunk fallback and reassembly. */
import { describe, expect, it } from "vitest";
import { FramedLink, MIN_CHUNK_LENGTH, type GattConnection } from "../../src/engine/transport";
import { FrameKind, Reassembler, chunk, encodeBtFrame } from "../../src/engine/wire";

/** A connection whose writes finish only when the test says so, and which records overlap. */
function slowConnection(options: { refuseAbove?: number } = {}) {
  const writes: Uint8Array[] = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const pending: Array<() => void> = [];
  const connection: GattConnection = {
    beacon: new Uint8Array(),
    write(piece) {
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      return new Promise<void>((resolve, reject) => {
        pending.push(() => {
          inFlight -= 1;
          if (options.refuseAbove !== undefined && piece.length > options.refuseAbove) {
            reject(new Error("NotSupportedError"));
            return;
          }
          writes.push(piece);
          resolve();
        });
      });
    },
    disconnect() {
      disconnected = true;
    },
  };
  let disconnected = false;
  return {
    connection,
    writes,
    get maxInFlight() {
      return maxInFlight;
    },
    get disconnected() {
      return disconnected;
    },
    /** Completes queued writes one by one until none are left. */
    async finishAll() {
      for (let i = 0; i < 10_000; i++) {
        await Promise.resolve();
        await Promise.resolve();
        const next = pending.shift();
        if (!next) {
          await new Promise((r) => setTimeout(r, 0));
          if (pending.length === 0) return;
          continue;
        }
        next();
      }
    },
  };
}

function reassemble(pieces: Uint8Array[]): Uint8Array[] {
  const r = new Reassembler();
  const frames: Uint8Array[] = [];
  for (const p of pieces) {
    const f = r.append(p);
    if (f) frames.push(f);
  }
  return frames;
}

describe("FramedLink", () => {
  it("writes one chunk at a time and keeps frames in order, never interleaved", async () => {
    const slow = slowConnection();
    const link = new FramedLink({ onFrame() {}, onFailed() {} }, 180);
    link.attach(slow.connection);
    const big = new Uint8Array(400).map((_, i) => i & 255);
    const small = new Uint8Array([1, 2, 3]);
    const first = link.send(FrameKind.data, big);
    const second = link.send(FrameKind.data, small);
    await slow.finishAll();
    await Promise.all([first, second]);
    expect(slow.maxInFlight).toBe(1);
    // 401-byte frame (kind + 400): 179 + 179 + 43 data bytes, plus one marker byte each.
    expect(slow.writes.map((w) => w.length)).toEqual([180, 180, 44, 5]);
    expect(slow.writes.every((w) => w.length <= 180)).toBe(true);
    expect(reassemble(slow.writes)).toEqual([encodeBtFrame(FrameKind.data, big), encodeBtFrame(FrameKind.data, small)]);
    // Same cut points as BluetoothWire.chunks in Swift.
    expect(slow.writes.slice(0, 3)).toEqual(chunk(encodeBtFrame(FrameKind.data, big), 180));
  });

  it("retries the rest of a frame with 20-byte chunks when a write is refused", async () => {
    const slow = slowConnection({ refuseAbove: MIN_CHUNK_LENGTH });
    let failed: string | null = null;
    const link = new FramedLink({ onFrame() {}, onFailed: (r) => (failed = r) }, 180);
    link.attach(slow.connection);
    const body = new Uint8Array(100).fill(7);
    const done = link.send(FrameKind.data, body);
    await slow.finishAll();
    await done;
    expect(failed).toBeNull();
    expect(link.chunkLength).toBe(MIN_CHUNK_LENGTH);
    expect(slow.writes.every((w) => w.length <= MIN_CHUNK_LENGTH)).toBe(true);
    expect(reassemble(slow.writes)).toEqual([encodeBtFrame(FrameKind.data, body)]);
  });

  it("fails the link when even small writes are refused", async () => {
    const slow = slowConnection({ refuseAbove: 0 });
    let failed: string | null = null;
    const link = new FramedLink({ onFrame() {}, onFailed: (r) => (failed = r) }, 180);
    link.attach(slow.connection);
    const done = link.send(FrameKind.data, new Uint8Array(10)).then(() => "ok", () => "rejected");
    const queued = link.send(FrameKind.close).then(() => "ok", () => "rejected");
    await slow.finishAll();
    expect(await done).toBe("rejected");
    expect(await queued).toBe("rejected");
    expect(failed).toBe("writeFailed");
    expect(slow.disconnected).toBe(true);
    await expect(link.send(FrameKind.close)).rejects.toThrow();
  });

  it("reassembles notifications into frames and rejects malformed or oversized input", () => {
    const frames: Array<[number, number]> = [];
    let failed: string | null = null;
    const link = new FramedLink({ onFrame: (k, b) => frames.push([k, b.length]), onFailed: (r) => (failed = r) });
    for (const piece of chunk(encodeBtFrame(FrameKind.data, new Uint8Array(500)), 20)) link.gattHandlers.onNotify(piece);
    link.gattHandlers.onNotify(new Uint8Array([1, 99])); // unknown kind: ignored, like the phone does
    expect(frames).toEqual([[FrameKind.data, 500]]);
    expect(failed).toBeNull();

    link.gattHandlers.onNotify(new Uint8Array([2, 1]));
    expect(failed).toBe("malformed");

    let tooBig: string | null = null;
    const other = new FramedLink({ onFrame() {}, onFailed: (r) => (tooBig = r) });
    for (let i = 0; i < 130 && !tooBig; i++) other.gattHandlers.onNotify(new Uint8Array(512));
    expect(tooBig).toBe("malformed");
  });

  it("reports a dropped connection once, and nothing after a local close", () => {
    const reasons: string[] = [];
    const link = new FramedLink({ onFrame() {}, onFailed: (r) => reasons.push(r) });
    link.gattHandlers.onDisconnected();
    link.gattHandlers.onDisconnected();
    expect(reasons).toEqual(["disconnected"]);
    const closed = new FramedLink({ onFrame() {}, onFailed: (r) => reasons.push(r) });
    closed.close();
    closed.gattHandlers.onDisconnected();
    expect(reasons).toEqual(["disconnected"]);
  });
});
