/**
 * Runs the real Swift `Messenger` as "the phone": EarshotKit's `earshot-probe` in `--pipe` mode
 * (Sources/EarshotProbe/PipeTransport.swift). Bluetooth operations travel as text lines over the
 * probe's stdin/stdout, and `ProbeDevice` turns them back into the engine's `Device` interface.
 *
 *   browser -> probe: "GATT connect", "GATT subscribe", "GATT read", "GATT write <base64>", "GATT disconnect"
 *   probe -> browser: "GATT subscribed", "GATT beacon <base64>", "GATT write-ok" / "GATT write-error <why>",
 *                     "GATT notify <base64>"
 *   other lines are the probe's own log: "CONNECTED Alex code 123 456 789", "RECEIVED hello", ...
 */
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ConnectError, type Device, type GattConnection, type GattHandlers } from "../../../src/engine/transport";

export const earshotKitDir = fileURLToPath(new URL("../../../../EarshotKit/", import.meta.url));
/**
 * A build folder of its own (outside the repository), so this test never rebuilds or replaces a
 * probe binary someone is already running from EarshotKit/.build.
 */
export const scratchPath = process.env.EARSHOT_PROBE_SCRATCH ?? join(tmpdir(), "earshot-web-probe-build");

export function swiftAvailable(): boolean {
  if (process.platform !== "darwin") return false;
  const result = spawnSync("swift", ["--version"], { encoding: "utf8" });
  return result.status === 0;
}

/** Builds the probe (debug, so --pipe is compiled in). Returns the binary path. */
export function buildProbe(): string {
  const result = spawnSync("swift", ["build", "--product", "earshot-probe", "--scratch-path", scratchPath], {
    cwd: earshotKitDir,
    encoding: "utf8",
    timeout: 600_000,
  });
  if (result.status !== 0) throw new Error(`swift build failed:\n${result.stdout}\n${result.stderr}`);
  return join(scratchPath, "debug", "earshot-probe");
}

type Waiter = { match: (line: string) => boolean; resolve: (line: string) => void };

export class Probe {
  readonly process: ChildProcessWithoutNullStreams;
  /** Every non-GATT line the probe printed. */
  readonly log: string[] = [];
  #waiters: Waiter[] = [];
  #gattWaiters: Waiter[] = [];
  #notify: ((chunk: Uint8Array) => void) | null = null;
  #buffer = "";
  #stderr = "";

  constructor(binary: string, args: string[]) {
    this.process = spawn(binary, args, { cwd: earshotKitDir });
    this.process.stdout.setEncoding("utf8");
    this.process.stdout.on("data", (data: string) => {
      this.#buffer += data;
      let newline: number;
      while ((newline = this.#buffer.indexOf("\n")) >= 0) {
        const line = this.#buffer.slice(0, newline);
        this.#buffer = this.#buffer.slice(newline + 1);
        this.#line(line);
      }
    });
    this.process.stderr.on("data", (data: Buffer) => {
      this.#stderr += data.toString();
    });
  }

  get stderr(): string {
    return this.#stderr;
  }

  #line(line: string): void {
    if (line.startsWith("GATT notify ")) {
      this.#notify?.(new Uint8Array(Buffer.from(line.slice("GATT notify ".length), "base64")));
      return;
    }
    if (line.startsWith("GATT ")) {
      const index = this.#gattWaiters.findIndex((w) => w.match(line));
      if (index >= 0) this.#gattWaiters.splice(index, 1)[0]!.resolve(line);
      return;
    }
    this.log.push(line);
    for (const waiter of [...this.#waiters]) {
      if (waiter.match(line)) {
        this.#waiters.splice(this.#waiters.indexOf(waiter), 1);
        waiter.resolve(line);
      }
    }
  }

  send(line: string): void {
    this.process.stdin.write(line + "\n");
  }

  /** Waits for a log line starting with `prefix` (counting only lines after `after` lines). */
  waitForLine(prefix: string, timeoutMs = 20_000, after = 0): Promise<string> {
    const existing = this.log.slice(after).find((l) => l.startsWith(prefix));
    if (existing) return Promise.resolve(existing);
    return this.#wait(this.#waiters, (l) => l.startsWith(prefix), timeoutMs, `probe line "${prefix}"`);
  }

  gatt(prefix: string, timeoutMs = 10_000): Promise<string> {
    return this.#wait(this.#gattWaiters, (l) => l.startsWith(prefix), timeoutMs, `"${prefix}"`);
  }

  #wait(list: Waiter[], match: (l: string) => boolean, timeoutMs: number, what: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const waiter: Waiter = {
        match,
        resolve: (line) => {
          clearTimeout(timer);
          resolve(line);
        },
      };
      const timer = setTimeout(() => {
        list.splice(list.indexOf(waiter), 1);
        reject(new Error(`timed out waiting for ${what}. Probe log:\n${this.log.join("\n")}\n${this.#stderr}`));
      }, timeoutMs);
      list.push(waiter);
    });
  }

  setNotifyHandler(handler: ((chunk: Uint8Array) => void) | null): void {
    this.#notify = handler;
  }

  stop(): void {
    this.process.stdin.end();
    setTimeout(() => this.process.kill(), 2_000).unref();
  }
}

/** The probe seen as a Bluetooth device the browser picked. */
export class ProbeDevice implements Device {
  readonly token = "probe-phone";
  /** Every chunk the engine wrote, for checking chunk sizes. */
  readonly written: Uint8Array[] = [];

  constructor(private readonly probe: Probe) {}

  async connect(handlers: GattHandlers): Promise<GattConnection> {
    const probe = this.probe;
    let alive = true;
    probe.send("GATT connect");
    // Subscribe first: the phone refuses writes from a browser that is not listening.
    probe.setNotifyHandler((piece) => {
      if (alive) handlers.onNotify(piece);
    });
    probe.send("GATT subscribe");
    await probe.gatt("GATT subscribed");
    probe.send("GATT read");
    const beaconLine = await probe.gatt("GATT beacon ").catch(() => {
      throw new ConnectError("unreachable");
    });
    const beacon = new Uint8Array(Buffer.from(beaconLine.slice("GATT beacon ".length), "base64"));
    return {
      beacon,
      write: async (piece) => {
        if (!alive) throw new Error("disconnected");
        this.written.push(piece.slice());
        probe.send(`GATT write ${Buffer.from(piece).toString("base64")}`);
        const answer = await probe.gatt("GATT write-");
        if (answer !== "GATT write-ok") throw new Error(answer);
      },
      disconnect: () => {
        if (!alive) return;
        alive = false;
        probe.setNotifyHandler(null);
        probe.send("GATT disconnect");
      },
    };
  }
}
