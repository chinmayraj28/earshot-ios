/**
 * Opt-in diagnostics. Silent unless `localStorage.earshotDebug` is set (any value), e.g. by
 * running `localStorage.earshotDebug = "1"` in the browser console and reloading.
 *
 * Callers must never pass names, keys or message text: only states, sizes and error kinds,
 * e.g. `debug("link", "handshake done", { chunks: 3 })`.
 */
let enabled: boolean | null = null;

function isEnabled(): boolean {
  if (enabled === null) {
    try {
      enabled = typeof localStorage !== "undefined" && localStorage.getItem("earshotDebug") !== null;
    } catch {
      enabled = false;
    }
  }
  return enabled;
}

export function debug(area: string, message: string, details?: Record<string, string | number | boolean>): void {
  if (!isEnabled()) return;
  console.debug(`[earshot:${area}] ${message}`, details ?? "");
}

/** Error kind without its message, which could in theory echo data. Example: "NetworkError". */
export function errorKind(error: unknown): string {
  return error instanceof Error ? error.name : typeof error;
}
