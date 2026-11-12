/**
 * Entry point for the interface.
 *
 *   createEngine()            the real engine: Web Bluetooth + IndexedDB in this browser.
 *   createDemoEngine("populated" | "empty" | "firstRun")
 *                             no Bluetooth, nothing saved, fixed sample data and timings.
 *
 * Diagnostics: set `localStorage.earshotDebug = "1"` and reload to see link states and error
 * kinds in the console. Names, keys and message text are never logged.
 */
import type { Engine } from "./api";
import { DemoEngine, type DemoOptions, type DemoScenario } from "./demo";
import { EarshotEngine } from "./engine";
import { IndexedDBStorage } from "./storage";
import { WebBluetoothTransport } from "./webBluetooth";

export function createEngine(): Engine {
  return new EarshotEngine({ transport: new WebBluetoothTransport(), storage: new IndexedDBStorage() });
}

export function createDemoEngine(scenario: DemoScenario, options?: DemoOptions): Engine {
  return new DemoEngine(scenario, options);
}

export type { DemoFindOutcome, DemoOptions, DemoScenario } from "./demo";
export { DemoTiming } from "./demo";
export * from "./api";
