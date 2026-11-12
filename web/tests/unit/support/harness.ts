/** Shared helpers for engine tests that run on fake timers. */
import { vi } from "vitest";
import { EarshotEngine, type EngineConfig } from "../../../src/engine/engine";
import { MemoryTransport } from "../../../src/engine/memoryTransport";
import { MemoryStorage, type Storage } from "../../../src/engine/storage";

export function makeEngine(options: { storage?: Storage; config?: Partial<EngineConfig>; name?: string } = {}) {
  const transport = new MemoryTransport();
  const storage = options.storage ?? new MemoryStorage();
  const engine = new EarshotEngine({ transport, storage, config: options.config, listenToPageLifecycle: false });
  return { engine, transport, storage };
}

/** Advances fake time in small steps until `condition` holds. Throws after `maxMs` of fake time. */
export async function waitFor(what: string, condition: () => boolean, maxMs = 5_000): Promise<void> {
  for (let elapsed = 0; elapsed <= maxMs; elapsed += 5) {
    if (condition()) return;
    await vi.advanceTimersByTimeAsync(5);
  }
  if (!condition()) throw new Error(`timed out waiting until ${what}`);
}

/** Lets pending promises and zero-delay work finish. */
export async function settle(ms = 50): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms);
}
