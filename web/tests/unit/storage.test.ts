/** IndexedDB storage round trip, using fake-indexeddb in place of the browser's database. */
import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { IndexedDBStorage } from "../../src/engine/storage";
import { EarshotEngine } from "../../src/engine/engine";
import { MemoryTransport } from "../../src/engine/memoryTransport";
import type { Contact, Message } from "../../src/engine/api";

describe("IndexedDBStorage", () => {
  it("saves and loads identity, profile, contacts and conversations", async () => {
    const storage = new IndexedDBStorage("earshot-test-1");
    expect((await storage.load()).identitySeed).toBeNull();
    const seed = new Uint8Array(32).fill(5);
    const contact: Contact = { id: "abc", displayName: "Maya", identityKey: new Uint8Array(32).fill(1), addedAt: 1, isBlocked: true, isVerified: true };
    const message: Message = { id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", direction: "outgoing", text: "hi 👋", timestamp: 2, status: "waiting" };
    await storage.saveIdentity(seed);
    await storage.saveProfile({ displayName: "Alex", hasCompletedOnboarding: true });
    await storage.saveContacts([contact]);
    await storage.saveConversation("abc", { messages: [message], unreadCount: 3 });
    await storage.saveConversation("gone", { messages: [], unreadCount: 0 });
    await storage.deleteConversation("gone");

    const loaded = await new IndexedDBStorage("earshot-test-1").load();
    expect(loaded.identitySeed).toEqual(seed);
    expect(loaded.profile).toEqual({ displayName: "Alex", hasCompletedOnboarding: true });
    expect(loaded.contacts).toEqual([contact]);
    expect([...loaded.conversations.keys()]).toEqual(["abc"]);
    expect(loaded.conversations.get("abc")).toEqual({ messages: [message], unreadCount: 3 });

    await storage.eraseAll();
    const erased = await storage.load();
    expect(erased.identitySeed).toBeNull();
    expect(erased.contacts).toEqual([]);
  });

  it("gives the engine the same identity after a reload", async () => {
    const make = () =>
      new EarshotEngine({ transport: new MemoryTransport(), storage: new IndexedDBStorage("earshot-test-2"), listenToPageLifecycle: false });
    const first = make();
    await first.ready();
    first.completeOnboarding("Alex");
    await first.flushStorage();
    const second = make();
    await second.ready();
    expect(second.identityKey).toEqual(first.identityKey);
    expect(second.getSnapshot().profile.displayName).toBe("Alex");
  });
});
