/**
 * Picks the engine from the address:
 *   ?demo=populated | ?demo=empty | ?demo=firstRun  -> in-memory demo engine, no Bluetooth.
 *   anything else                                   -> the real Web Bluetooth engine.
 *
 * For the demo engine, &find=<outcome>[,<outcome>...] chooses what each click on
 * "Find a nearby phone" does, in order, so every progress and failure screen can be shown
 * and tested without a phone. Example: ?demo=empty&find=declined,newContact
 * The outcome names are the demo engine's own (see DemoFindOutcome in src/engine/demo.ts).
 */
import type { Engine } from "../engine/api";
import { createDemoEngine, createEngine, type DemoFindOutcome, type DemoScenario } from "../engine/index";

const SCENARIOS: readonly DemoScenario[] = ["populated", "empty", "firstRun"];

export function demoScenario(search = window.location.search): DemoScenario | null {
  const value = new URLSearchParams(search).get("demo");
  return SCENARIOS.includes(value as DemoScenario) ? (value as DemoScenario) : null;
}

export async function chooseEngine(): Promise<Engine> {
  const scenario = demoScenario();
  if (!scenario) return createEngine();
  const find = new URLSearchParams(window.location.search).get("find");
  const findOutcomes = find
    ? (find.split(",").map((part) => part.trim()).filter(Boolean) as DemoFindOutcome[])
    : undefined;
  return createDemoEngine(scenario, { findOutcomes });
}
