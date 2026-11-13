/**
 * The engine against a pretend phone (support/fakePhone.ts) over the in-memory transport.
 * Everything runs on fake timers, so "10 seconds without a receipt" takes no real time.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ContactID } from "../../src/engine/api";
import { safetyCode } from "../../src/engine/crypto";
import type { EarshotEngine } from "../../src/engine/engine";
import { MemoryStorage } from "../../src/engine/storage";
import { FrameKind, chunk, encodeBtFrame, encodeHello } from "../../src/engine/wire";
import { FakePhone } from "./support/fakePhone";
import { makeEngine, settle, waitFor } from "./support/harness";

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

async function onboarded(name = "Alex", storage?: MemoryStorage) {
  const setup = makeEngine({ storage });
  await setup.engine.ready();
  setup.engine.completeOnboarding(name);
  return setup;
}

/** Picks the phone in the "chooser" and waits until the link is open. */
async function befriend(engine: EarshotEngine, transport: { choices: unknown[] }, phone: FakePhone): Promise<ContactID> {
  transport.choices.push(phone.device);
  const result = await engine.findNearby();
  expect(result.kind).toBe("started");
  await waitFor("connected", () => engine.getSnapshot().conversations.some((c) => c.link === "connected"));
  return phone.contactID;
}

const linkOf = (engine: EarshotEngine, id: ContactID) => engine.getSnapshot().conversations.find((c) => c.contact.id === id)?.link;
const statusOf = (engine: EarshotEngine, id: ContactID, messageID: string) => engine.messages(id).find((m) => m.id === messageID)?.status;

describe("first connection", () => {
  it("sends a request, gets accepted, and both sides show the same safety code", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { autoAccept: false });
    const events: string[] = [];
    engine.onEvent((e) => events.push(e.kind));
    transport.choices.push(phone.device);

    const result = await engine.findNearby();
    expect(result).toEqual({ kind: "started", peer: "phone-1", contactID: null });
    await settle();
    expect(engine.getSnapshot().requests).toEqual([{ id: "phone-1", displayName: "Jensen Huang", state: { kind: "waiting" } }]);
    expect(phone.invites[0]?.name).toBe("Alex");
    expect(phone.invites[0]?.tag).toBeUndefined();

    phone.acceptPending();
    await waitFor("connected", () => engine.getSnapshot().requests[0]?.state.kind === "connected");
    const id = phone.contactID;
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "connected", contactID: id });
    expect(engine.getSnapshot().contacts.map((c) => c.displayName)).toEqual(["Jensen Huang"]);
    expect(linkOf(engine, id)).toBe("connected");
    expect(events).toContain("connected");
    expect(engine.safetyCode(id)).toBe(safetyCode(phone.identity.publicKey, engine.identityKey));
    expect(phone.contacts.get(engine.getSnapshot().contacts[0]!.id)).toBeUndefined(); // phone stores by OUR id
    expect(phone.contacts.size).toBe(1);
    expect(phone.isLinked).toBe(true);
  });

  it("reports a declined request as noAnswer and lets go of the phone", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { autoAccept: false });
    transport.choices.push(phone.device);
    await engine.findNearby();
    await settle();
    phone.declinePending();
    await waitFor("failed", () => engine.getSnapshot().requests[0]?.state.kind === "failed");
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "failed", failure: "noAnswer" });
    expect(phone.device.isConnected).toBe(false);
    engine.dismiss("phone-1");
    expect(engine.getSnapshot().requests).toEqual([]);
  });

  it("gives up on an unanswered request after 45 seconds and withdraws it", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { autoAccept: false });
    transport.choices.push(phone.device);
    await engine.findNearby();
    await settle();
    await vi.advanceTimersByTimeAsync(44_000);
    expect(engine.getSnapshot().requests[0]?.state.kind).toBe("waiting");
    await vi.advanceTimersByTimeAsync(2_000);
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "failed", failure: "noAnswer" });
    expect(phone.frameKinds).toContain(FrameKind.close);
  });

  it("dismissing a waiting request cancels it on the phone", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { autoAccept: false });
    transport.choices.push(phone.device);
    await engine.findNearby();
    await settle();
    engine.dismiss("phone-1");
    await settle();
    expect(phone.frameKinds).toEqual([FrameKind.invite, FrameKind.close]);
    expect(phone.device.isConnected).toBe(false);
  });

  it("fails with verificationFailed when the phone's proof is wrong", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    // A phone that signs with one key but claims another.
    const impostor = new FakePhone("x");
    Object.defineProperty(phone, "identity", { value: { seed: phone.identity.seed, publicKey: impostor.identity.publicKey } });
    transport.choices.push(phone.device);
    await engine.findNearby();
    await waitFor("failed", () => engine.getSnapshot().requests[0]?.state.kind === "failed");
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "failed", failure: "verificationFailed" });
    expect(engine.getSnapshot().contacts).toEqual([]);
  });

  it("reports incompatibleVersion for a hello with another version", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { autoAccept: false });
    transport.choices.push(phone.device);
    await engine.findNearby();
    await settle();
    // Accept by hand, then send a version-2 hello.
    phone.sendRawChunk(new Uint8Array([1, FrameKind.accept]));
    for (const piece of chunk(encodeBtFrame(FrameKind.data, encodeHello(2, new Uint8Array(32).fill(9))), 20)) phone.sendRawChunk(piece);
    await waitFor("failed", () => engine.getSnapshot().requests[0]?.state.kind === "failed");
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "failed", failure: "incompatibleVersion" });
  });

  it("handles a cancelled chooser, a non-Earshot device and an unreachable one", async () => {
    const { engine, transport } = await onboarded();
    transport.choices.push("cancel");
    expect(await engine.findNearby()).toEqual({ kind: "cancelled" });

    const broken = new FakePhone("broken");
    broken.beaconOverride = new Uint8Array([7, 7, 7]);
    transport.choices.push(broken.device);
    expect(await engine.findNearby()).toEqual({ kind: "failed", reason: "notEarshot" });
    expect(broken.device.isConnected).toBe(false);

    const away = new FakePhone("away");
    away.inRange = false;
    transport.choices.push(away.device);
    expect(await engine.findNearby()).toEqual({ kind: "failed", reason: "unreachable" });
    expect(engine.getSnapshot().isFinding).toBe(false);
  });

  it("refuses to look for phones before onboarding or without Bluetooth", async () => {
    const { engine, transport } = makeEngine();
    await engine.ready();
    expect(await engine.findNearby()).toEqual({ kind: "failed", reason: "unavailable" });
    engine.completeOnboarding("Alex");
    transport.setAvailability("bluetoothOff");
    expect(engine.getSnapshot().availability).toBe("bluetoothOff");
    expect(await engine.findNearby()).toEqual({ kind: "failed", reason: "unavailable" });
  });
});

describe("messages", () => {
  it("goes sending -> delivered, and the phone receives the text", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    const message = engine.send("  hello there \n", id)!;
    expect(message.text).toBe("hello there");
    expect(message.status).toBe("sending");
    expect(message.id).toMatch(/^[0-9A-F-]{36}$/);
    await waitFor("delivered", () => statusOf(engine, id, message.id) === "delivered");
    expect(phone.texts).toEqual(["hello there"]);
  });

  it("rejects empty, too long, unknown-contact and blocked sends", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    expect(engine.send("   ", id)).toBeNull();
    expect(engine.send("x".repeat(2001), id)).toBeNull();
    expect(engine.send("👋🏽".repeat(2000), id)).not.toBeNull(); // 2,000 characters, 8,000 UTF-16 units
    expect(engine.send("hi", "nobody")).toBeNull();
    engine.setBlocked(true, id);
    expect(engine.send("hi", id)).toBeNull();
  });

  it("marks a message failed when no receipt arrives in 10 seconds, and retry sends it again", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1", { ack: false });
    const id = await befriend(engine, transport, phone);
    const message = engine.send("anyone?", id)!;
    await vi.advanceTimersByTimeAsync(9_900);
    expect(statusOf(engine, id, message.id)).toBe("sending");
    await vi.advanceTimersByTimeAsync(200);
    expect(statusOf(engine, id, message.id)).toBe("failed");

    phone.options.ack = true;
    engine.retry(message.id, id);
    expect(statusOf(engine, id, message.id)).toBe("sending");
    await waitFor("delivered", () => statusOf(engine, id, message.id) === "delivered");
    expect(phone.texts).toEqual(["anyone?", "anyone?"]);
  });

  it("stores incoming messages once, counts unread, and confirms each copy", async () => {
    const { engine, transport, storage } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    const received: string[] = [];
    engine.onEvent((e) => {
      if (e.kind === "messageReceived") received.push(e.message.text);
    });
    const messageID = phone.sendText("are you there?");
    await waitFor("ack", () => phone.payloads.some((p) => p.kind === "ack"));
    expect(received).toEqual(["are you there?"]);
    expect(engine.getSnapshot().conversations[0]?.unreadCount).toBe(1);
    expect(engine.messages(id).at(-1)).toMatchObject({ id: messageID, direction: "incoming", status: "delivered" });
    // The receipt went out only after the message was stored.
    expect((await storage.load()).conversations.get(id)?.messages.some((m) => m.id === messageID)).toBe(true);

    // A resend (the phone missed our receipt) is confirmed again but not stored twice.
    phone.sendText("are you there?", messageID);
    await waitFor("second ack", () => phone.payloads.filter((p) => p.kind === "ack").length === 2);
    expect(engine.messages(id).filter((m) => m.id === messageID)).toHaveLength(1);

    engine.setActiveConversation(id);
    expect(engine.getSnapshot().conversations[0]?.unreadCount).toBe(0);
    phone.sendText("second");
    await waitFor("third ack", () => phone.payloads.filter((p) => p.kind === "ack").length === 3);
    expect(engine.getSnapshot().conversations[0]?.unreadCount).toBe(0);
  });

  it("does not confirm a message it could not store", async () => {
    const storage = new MemoryStorage();
    const { engine, transport } = await onboarded("Alex", storage);
    const phone = new FakePhone("phone-1");
    await befriend(engine, transport, phone);
    storage.failWrites = true;
    phone.sendText("will this be saved?");
    await settle(500);
    expect(phone.payloads.some((p) => p.kind === "ack")).toBe(false);
  });

  it("keeps only the newest 5,000 messages", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    engine.disconnect(id);
    let first = "";
    for (let i = 0; i < 5_003; i++) {
      const m = engine.send(`m${i}`, id)!;
      if (i === 3) first = m.id;
    }
    const messages = engine.messages(id);
    expect(messages).toHaveLength(5_000);
    expect(messages[0]?.id).toBe(first);
  });
});

describe("waiting messages and reconnection", () => {
  it("parks messages while disconnected and sends them after reconnecting through the knock path", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);

    engine.disconnect(id);
    await settle();
    expect(linkOf(engine, id)).toBe("outOfRange");
    const byeIndex = phone.payloads.findIndex((p) => p.kind === "bye");
    expect(byeIndex).toBeGreaterThanOrEqual(0); // the phone was told we left
    expect(phone.frameKinds.at(-1)).toBe(FrameKind.close);
    expect(phone.device.isConnected).toBe(false);

    const queued = engine.send("see you at the gate", id)!;
    await settle(5_000);
    expect(queued.status).toBe("waiting");
    expect(statusOf(engine, id, queued.id)).toBe("waiting"); // no automatic re-link after a manual disconnect

    transport.choices.push(phone.device);
    expect(await engine.findNearby()).toEqual({ kind: "started", peer: "phone-1", contactID: id });
    await waitFor("delivered", () => statusOf(engine, id, queued.id) === "delivered");
    const reconnection = phone.invites.at(-1)!;
    expect(reconnection.name).toBeUndefined(); // a reconnection carries no name...
    expect(reconnection.tag?.length).toBe(16); // ...only a PairTag
    expect(phone.payloads.some((p) => p.kind === "knock")).toBe(true);
    // No new prompt or request for a saved contact: only the finished one from the first meeting.
    expect(engine.getSnapshot().requests.map((r) => r.state.kind)).toEqual(["connected"]);
  });

  it("re-links by itself after the connection drops, without a click", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    const inFlight = engine.send("one", id)!;
    phone.options.ack = false;
    const unconfirmed = engine.send("two", id)!;
    await settle();
    phone.drop();
    await settle(10);
    expect(linkOf(engine, id)).toBe("connecting");
    expect(statusOf(engine, id, unconfirmed.id)).toBe("waiting");
    phone.options.ack = true;
    await waitFor("connected again", () => linkOf(engine, id) === "connected", 3_000);
    expect(phone.connections).toBe(2);
    await waitFor("resent and delivered", () => statusOf(engine, id, unconfirmed.id) === "delivered");
    expect(statusOf(engine, id, inFlight.id)).toBe("delivered");
  });

  it("re-links after the phone restarts Earshot (new session number)", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    phone.restart();
    await waitFor("connected again", () => phone.connections === 2 && linkOf(engine, id) === "connected", 3_000);
  });

  it("gives up after the backoff and shows the contact out of range", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    phone.inRange = false;
    phone.drop();
    await settle(10);
    expect(linkOf(engine, id)).toBe("connecting");
    await vi.advanceTimersByTimeAsync(1_000 + 2_000 + 4_000 + 8_000 + 8_000 + 500);
    expect(linkOf(engine, id)).toBe("outOfRange");
    // Sending a message tries once more right away, still without a click.
    phone.inRange = true;
    const m = engine.send("back?", id)!;
    await waitFor("delivered", () => statusOf(engine, id, m.id) === "delivered");
  });

  it("a phone that forgot us declines the reconnection silently", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    engine.disconnect(id);
    phone.contacts.clear();
    transport.choices.push(phone.device);
    await engine.findNearby();
    await settle(100);
    expect(phone.payloads.filter((p) => p.kind === "auth")).toHaveLength(1); // only from the first link
    await vi.advanceTimersByTimeAsync(30_000);
    expect(linkOf(engine, id)).toBe("outOfRange");
  });
});

describe("blocked contacts", () => {
  it("closes the link, never reconnects, and never delivers", async () => {
    const { engine, transport } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    engine.setBlocked(true, id);
    await settle();
    expect(linkOf(engine, id)).toBe("outOfRange");
    expect(phone.device.isConnected).toBe(false);
    expect(engine.getSnapshot().contacts[0]?.isBlocked).toBe(true);
    await vi.advanceTimersByTimeAsync(30_000);
    expect(phone.connections).toBe(1);

    const invitesBefore = phone.invites.length;
    transport.choices.push(phone.device);
    expect(await engine.findNearby()).toEqual({ kind: "failed", reason: "unavailable" });
    await settle();
    expect(phone.invites.length).toBe(invitesBefore);
    expect(phone.device.isConnected).toBe(false);

    engine.setBlocked(false, id);
    await waitFor("connected after unblocking", () => linkOf(engine, id) === "connected");
  });

  it("removing a contact forgets it and its messages", async () => {
    const { engine, transport, storage } = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(engine, transport, phone);
    engine.send("bye", id);
    engine.removeContact(id);
    await engine.flushStorage();
    expect(engine.getSnapshot().contacts).toEqual([]);
    expect(engine.messages(id)).toEqual([]);
    expect((await storage.load()).conversations.has(id)).toBe(false);
    expect(engine.safetyCode(id)).toBeNull();
  });

  it("toggles the verified flag", async () => {
    const { engine, transport } = await onboarded();
    const id = await befriend(engine, transport, new FakePhone("phone-1"));
    engine.setVerified(true, id);
    expect(engine.getSnapshot().contacts[0]?.isVerified).toBe(true);
  });
});

describe("malformed input from the phone closes the link instead of throwing", () => {
  async function linked() {
    const setup = await onboarded();
    const phone = new FakePhone("phone-1");
    const id = await befriend(setup.engine, setup.transport, phone);
    return { ...setup, phone, id };
  }

  const cases: Array<[string, (phone: FakePhone) => void]> = [
    ["garbage instead of a sealed frame", (p) => p.sendData(new Uint8Array([2, 1, 2, 3]))],
    ["an unknown engine frame kind", (p) => p.sendData(new Uint8Array([9, 9]))],
    ["a second hello", (p) => p.sendData(encodeHello(1, new Uint8Array(32).fill(3)))],
    ["a bad chunk marker", (p) => p.sendRawChunk(new Uint8Array([7, 1, 2]))],
    ["a frame bigger than 64 KB", (p) => {
      const piece = new Uint8Array(512);
      for (let i = 0; i < 130; i++) p.sendRawChunk(piece);
    }],
    ["an auth after the link is established", (p) =>
      p.sendPayload({ kind: "auth", identityKey: p.identity.publicKey, name: "x", signature: new Uint8Array(64) })],
    ["an empty text", (p) => p.sendPayload({ kind: "text", id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", text: "" })],
    ["a text over 2,000 characters", (p) => p.sendPayload({ kind: "text", id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", text: "a".repeat(2001) })],
    ["a flood of messages", (p) => {
      for (let i = 0; i < 61; i++) p.sendText(`spam ${i}`);
    }],
  ];

  for (const [label, attack] of cases) {
    it(label, async () => {
      const { engine, phone, id } = await linked();
      attack(phone);
      await waitFor("link closed", () => linkOf(engine, id) !== "connected");
      await settle();
      expect(phone.connections).toBeGreaterThanOrEqual(1);
    });
  }

  it("a replayed sealed frame", async () => {
    const { engine, phone, id } = await linked();
    const sealed = phone.sealForLater({ kind: "ack", id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301" });
    phone.sendData(sealed);
    await settle();
    expect(linkOf(engine, id)).toBe("connected");
    phone.sendData(sealed);
    await waitFor("link closed", () => linkOf(engine, id) !== "connected");
  });

  it("the phone saying bye", async () => {
    const { engine, phone, id } = await linked();
    phone.sendPayload({ kind: "bye" });
    await waitFor("link closed", () => linkOf(engine, id) !== "connected");
  });
});

describe("storage and erasing", () => {
  it("keeps identity, contacts and messages across a restart, and parks 'sending' messages", async () => {
    const storage = new MemoryStorage();
    const first = await onboarded("Alex", storage);
    const phone = new FakePhone("phone-1", { ack: false });
    const id = await befriend(first.engine, first.transport, phone);
    const message = first.engine.send("in flight", id)!;
    await first.engine.flushStorage();
    const code = first.engine.safetyCode(id);
    first.engine.dispose();

    const second = makeEngine({ storage });
    await second.engine.ready();
    expect(second.engine.getSnapshot().profile).toEqual({ displayName: "Alex", hasCompletedOnboarding: true });
    expect(second.engine.safetyCode(id)).toBe(code);
    expect(second.engine.messages(id).find((m) => m.id === message.id)?.status).toBe("waiting");
  });

  it("erase everything replaces the identity and forgets all contacts", async () => {
    const storage = new MemoryStorage();
    const { engine, transport } = await onboarded("Alex", storage);
    const phone = new FakePhone("phone-1");
    await befriend(engine, transport, phone);
    const before = engine.identityKey;
    await engine.eraseEverything();
    expect(engine.identityKey).not.toEqual(before);
    expect(engine.getSnapshot().contacts).toEqual([]);
    expect(engine.getSnapshot().profile.hasCompletedOnboarding).toBe(false);
    const stored = await storage.load();
    expect(stored.contacts).toEqual([]);
    expect(stored.identitySeed).not.toBeNull();
    expect(phone.payloads.some((p) => p.kind === "bye")).toBe(true);
  });

  it("returns the same snapshot object until something changes", async () => {
    const { engine } = await onboarded();
    const a = engine.getSnapshot();
    expect(engine.getSnapshot()).toBe(a);
    let calls = 0;
    const unsubscribe = engine.subscribe(() => calls++);
    engine.setDisplayName("Alex B");
    expect(calls).toBe(1);
    expect(engine.getSnapshot()).not.toBe(a);
    expect(engine.getSnapshot().profile.displayName).toBe("Alex B");
    unsubscribe();
  });
});
