/** Hands the engine to every screen and keeps React in step with its snapshots. */
import { createContext, useCallback, useContext, useSyncExternalStore, type ReactNode } from "react";
import type { Engine, Snapshot } from "../engine/api";

const EngineContext = createContext<Engine | null>(null);

export function EngineProvider({ engine, children }: { engine: Engine; children: ReactNode }) {
  return <EngineContext.Provider value={engine}>{children}</EngineContext.Provider>;
}

export function useEngine(): Engine {
  const engine = useContext(EngineContext);
  if (!engine) throw new Error("useEngine must be used inside EngineProvider");
  return engine;
}

/** The latest snapshot. Re-renders whenever the engine reports a change. */
export function useSnapshot(): Snapshot {
  const engine = useEngine();
  const subscribe = useCallback((listener: () => void) => engine.subscribe(listener), [engine]);
  const getSnapshot = useCallback(() => engine.getSnapshot(), [engine]);
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}
