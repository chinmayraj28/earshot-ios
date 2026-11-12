/** The demo engine must behave the same way every time: the interface's tests depend on it. */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DemoTiming, createDemoEngine } from "../../src/engine/index";

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-03-14T09:41:00Z"));
});
afterEach(() => vi.useRealTimers());

describe("demo engine", () => {
  it("starts with the three scenarios", async () => {
    const first = createDemoEngine("firstRun");
    await first.ready();
    expect(first.getSnapshot().profile).toEqual({ displayName: "", hasCompletedOnboarding: false });
    const empty = createDemoEngine("empty");
    expect(empty.getSnapshot().profile.displayName).toBe("Chinmay");
    expect(empty.getSnapshot().contacts).toEqual([]);
    const populated = createDemoEngine("populated").getSnapshot();
    expect(populated.availability).toBe("ready");
    expect(populated.conversations.map((c) => [c.contact.displayName, c.link, c.unreadCount])).toEqual([
      ["Priya Raman", "connected", 2],
      ["Maya Okafor", "connected", 0],
      ["Jonas Weber", "outOfRange", 0],
      ["Sam Lee", "outOfRange", 0],
    ]);
    expect(populated.contacts.find((c) => c.displayName === "Sam Lee")?.isBlocked).toBe(true);
  });

  it("is deterministic: same IDs and safety codes every time", () => {
    const a = createDemoEngine("populated");
    const b = createDemoEngine("populated");
    expect(a.getSnapshot().contacts.map((c) => c.id)).toEqual(b.getSnapshot().contacts.map((c) => c.id));
    const id = a.getSnapshot().contacts[0]!.id;
    expect(a.safetyCode(id)).toBe(b.safetyCode(id));
    expect(a.safetyCode(id)).toMatch(/^\d{3} \d{3} \d{3}$/);
    expect(a.messages(id).map((m) => m.id)).toEqual(b.messages(id).map((m) => m.id));
  });

  it("finds a new person who accepts, then greets", async () => {
    const engine = createDemoEngine("empty");
    const events: string[] = [];
    engine.onEvent((e) => events.push(e.kind));
    const pending = engine.findNearby();
    expect(engine.getSnapshot().isFinding).toBe(true);
    await vi.advanceTimersByTimeAsync(DemoTiming.chooserMs);
    expect(await pending).toEqual({ kind: "started", peer: "demo-peer-1", contactID: null });
    expect(engine.getSnapshot().requests[0]).toMatchObject({ displayName: "Noor Haddad", state: { kind: "waiting" } });
    await vi.advanceTimersByTimeAsync(DemoTiming.acceptMs);
    expect(engine.getSnapshot().requests[0]?.state.kind).toBe("connecting");
    await vi.advanceTimersByTimeAsync(DemoTiming.connectMs);
    const id = engine.getSnapshot().contacts[0]!.id;
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "connected", contactID: id });
    expect(engine.getSnapshot().conversations[0]?.link).toBe("connected");
    await vi.advanceTimersByTimeAsync(DemoTiming.greetingMs);
    expect(engine.messages(id)).toHaveLength(1);
    expect(events).toEqual(["connected", "messageReceived"]);
  });

  it("delivers to connected contacts and keeps messages waiting for out-of-range ones", async () => {
    const engine = createDemoEngine("populated", { findOutcomes: ["savedContact"] });
    const [maya, jonas] = ["Maya Okafor", "Jonas Weber"].map((n) => engine.getSnapshot().contacts.find((c) => c.displayName === n)!.id);
    const sent = engine.send("on my way", maya!)!;
    expect(sent.status).toBe("sending");
    await vi.advanceTimersByTimeAsync(DemoTiming.deliverMs);
    expect(engine.messages(maya!).at(-1)?.status).toBe("delivered");

    const waiting = engine.send("still there?", jonas!)!;
    expect(waiting.status).toBe("waiting");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(engine.messages(jonas!).at(-1)?.status).toBe("waiting");

    const found = engine.findNearby();
    await vi.advanceTimersByTimeAsync(DemoTiming.chooserMs);
    expect(await found).toMatchObject({ kind: "started", contactID: jonas });
    await vi.advanceTimersByTimeAsync(DemoTiming.reconnectMs + DemoTiming.deliverMs);
    expect(engine.messages(jonas!).filter((m) => m.direction === "outgoing").every((m) => m.status === "delivered")).toBe(true);
  });

  it("fails requests in each requested way, and auto-replies when asked", async () => {
    const engine = createDemoEngine("populated", {
      findOutcomes: ["connectionLost", "verificationFailed", "incompatibleVersion", "unavailable"],
      autoReply: true,
    });
    const results = [];
    for (let i = 0; i < 4; i++) {
      const p = engine.findNearby();
      await vi.advanceTimersByTimeAsync(DemoTiming.chooserMs);
      results.push(await p);
    }
    expect(results.at(-1)).toEqual({ kind: "failed", reason: "unavailable" });
    await vi.advanceTimersByTimeAsync(DemoTiming.acceptMs);
    expect(engine.getSnapshot().requests.map((r) => r.state)).toEqual([
      { kind: "failed", failure: "connectionLost" },
      { kind: "failed", failure: "verificationFailed" },
      { kind: "failed", failure: "incompatibleVersion" },
    ]);
    const maya = engine.getSnapshot().contacts.find((c) => c.displayName === "Maya Okafor")!.id;
    const received: string[] = [];
    engine.onEvent((e) => e.kind === "messageReceived" && received.push(e.message.text));
    engine.send("meet at the stairs?", maya);
    await vi.advanceTimersByTimeAsync(DemoTiming.deliverMs + DemoTiming.replyMs);
    expect(received).toEqual(["Got it 👍"]);
  });

  it("supports declined, cancelled and failed finds, and erasing", async () => {
    const engine = createDemoEngine("populated", { findOutcomes: ["declined", "cancelled", "notEarshot"] });
    const results = [];
    for (let i = 0; i < 3; i++) {
      const p = engine.findNearby();
      await vi.advanceTimersByTimeAsync(DemoTiming.chooserMs);
      results.push(await p);
    }
    expect(results.map((r) => r.kind)).toEqual(["started", "cancelled", "failed"]);
    await vi.advanceTimersByTimeAsync(DemoTiming.acceptMs);
    expect(engine.getSnapshot().requests[0]?.state).toEqual({ kind: "failed", failure: "noAnswer" });
    await engine.eraseEverything();
    expect(engine.getSnapshot().contacts).toEqual([]);
    expect(engine.getSnapshot().profile.hasCompletedOnboarding).toBe(false);
  });
});
