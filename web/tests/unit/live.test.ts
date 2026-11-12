/**
 * Live interop without a radio: the real TypeScript engine against the real Swift Messenger.
 *
 * The Swift side is `earshot-probe --pipe`, which carries the exact Bluetooth frames (chunked,
 * with the phone's peripheral rules: subscribe before writing, 4 KB cap before a link exists)
 * over stdin/stdout. Only the radio is pretend; every byte above it is produced and checked by
 * the code that runs on the iPhone.
 *
 * Covered: request -> accepted -> handshake -> equal safety codes -> text delivered -> echo
 * received -> disconnect (bye) -> reconnect as a saved contact (PairTag + knock, no prompt on the
 * phone) -> the message queued meanwhile is delivered -> a long multi-chunk message both ways.
 *
 * Skipped when `swift` is not available (needs macOS with the Swift toolchain).
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { ContactID } from "../../src/engine/api";
import { EarshotEngine } from "../../src/engine/engine";
import { MemoryTransport } from "../../src/engine/memoryTransport";
import { MemoryStorage } from "../../src/engine/storage";
import { DEFAULT_CHUNK_LENGTH } from "../../src/engine/transport";
import { Probe, ProbeDevice, buildProbe, swiftAvailable } from "./support/probe";

const canRun = swiftAvailable() && !process.env.EARSHOT_SKIP_LIVE;
if (!canRun) {
  console.warn("live.test.ts skipped: needs macOS with `swift` on PATH (or EARSHOT_SKIP_LIVE is set).");
}

async function until(what: string, condition: () => boolean, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting until ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

describe.skipIf(!canRun)("live: TypeScript engine <-> Swift Messenger over the probe pipe", () => {
  let probe: Probe;
  let device: ProbeDevice;
  let engine: EarshotEngine;
  let transport: MemoryTransport;

  beforeAll(() => {
    const binary = buildProbe();
    // 20-byte notifications: the smallest Bluetooth packet, so the phone's frames arrive in many chunks.
    probe = new Probe(binary, ["--name", "Mac Probe", "--echo", "--pipe", "20"]);
    device = new ProbeDevice(probe);
    transport = new MemoryTransport();
    engine = new EarshotEngine({ transport, storage: new MemoryStorage(), listenToPageLifecycle: false });
  }, 600_000);

  afterAll(() => {
    engine?.dispose();
    probe?.stop();
  });

  const linkOf = (id: ContactID) => engine.getSnapshot().conversations.find((c) => c.contact.id === id)?.link;
  const statusOf = (id: ContactID, messageID: string) => engine.messages(id).find((m) => m.id === messageID)?.status;
  const incoming = (id: ContactID) => engine.messages(id).filter((m) => m.direction === "incoming").map((m) => m.text);

  it("connects, delivers, disconnects, reconnects as a saved contact and flushes the queue", async () => {
    await probe.waitForLine("STARTED as Mac Probe over pipe");
    await engine.ready();
    engine.completeOnboarding("Alex");

    // 1. A new request. The probe accepts every request, like a person tapping Accept.
    transport.choices.push(device);
    const found = await engine.findNearby();
    expect(found).toEqual({ kind: "started", peer: "probe-phone", contactID: null });
    expect(engine.getSnapshot().requests[0]?.displayName).toBe("Mac Probe");
    await probe.waitForLine("REQUEST from Alex");
    await until("request connected", () => engine.getSnapshot().requests[0]?.state.kind === "connected");
    const id = engine.getSnapshot().contacts[0]!.id;
    expect(engine.getSnapshot().contacts[0]!.displayName).toBe("Mac Probe");

    // 2. Both sides compute the same safety code.
    const connectedLine = await probe.waitForLine("CONNECTED Alex code ");
    expect(connectedLine.slice("CONNECTED Alex code ".length)).toBe(engine.safetyCode(id));

    // 3. A message goes out and comes back as an echo.
    const hello = engine.send("hello from the browser", id)!;
    await until("delivered", () => statusOf(id, hello.id) === "delivered");
    await probe.waitForLine("RECEIVED hello from the browser");
    await until("echo received", () => incoming(id).includes("Echo: hello from the browser"));
    // Our receipt for the echo reached the phone.
    await probe.waitForLine("DELIVERED Echo: hello from the browser");

    // 4. Disconnect: the phone is told ("bye"), and messages written now wait.
    engine.disconnect(id);
    expect(linkOf(id)).toBe("outOfRange");
    const queued = engine.send("queued while away", id)!;
    await new Promise((r) => setTimeout(r, 1_000));
    expect(statusOf(id, queued.id)).toBe("waiting");

    // 5. Reconnect: the beacon is recognised (DiscoveryTag), the invitation carries a PairTag and
    //    no name, both sides knock before revealing themselves. The phone shows no prompt.
    const logBefore = probe.log.length;
    transport.choices.push(device);
    expect(await engine.findNearby()).toEqual({ kind: "started", peer: "probe-phone", contactID: id });
    await until("reconnected", () => linkOf(id) === "connected");
    await probe.waitForLine("CONNECTED Alex code ", 20_000, logBefore);
    expect(probe.log.filter((l) => l.startsWith("REQUEST from"))).toHaveLength(1);

    // 6. The queued message is delivered and echoed.
    await until("queued delivered", () => statusOf(id, queued.id) === "delivered");
    await until("queued echo", () => incoming(id).includes("Echo: queued while away"));

    // 7. A long message: many 180-byte writes one way, many 20-byte notifications back.
    const long = "Long message with emoji 🌙 and accents é. ".repeat(35).trim();
    const sent = engine.send(long, id)!;
    await until("long delivered", () => statusOf(id, sent.id) === "delivered");
    await until("long echo", () => incoming(id).includes(`Echo: ${long}`));
    expect(device.written.every((w) => w.length <= DEFAULT_CHUNK_LENGTH)).toBe(true);
    expect(device.written.filter((w) => w.length === DEFAULT_CHUNK_LENGTH).length).toBeGreaterThan(5);
    if (process.env.EARSHOT_SHOW_PROBE_LOG) console.log(probe.log.join("\n"));
  }, 120_000);
});
