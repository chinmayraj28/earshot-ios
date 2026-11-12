/**
 * Small per-browser preferences kept in localStorage. Every read and write is wrapped in
 * try/catch because storage can be blocked (private windows, strict site settings); the app
 * then simply uses the defaults.
 */
import { useSyncExternalStore } from "react";

const KEYS = {
  /** "Show message text in notifications". Off unless the person turns it on. */
  showText: "earshot.notifications.showText",
  /** The person answered the in-page notification offer ("Turn on" or "Not now"). */
  offerAnswered: "earshot.notifications.offerAnswered",
  /** A contact has connected at least once, so the notification offer may be shown. */
  hasConnected: "earshot.hasConnected",
} as const;

type Key = keyof typeof KEYS;
const listeners = new Set<() => void>();

function read(key: Key): boolean {
  try {
    return window.localStorage.getItem(KEYS[key]) === "1";
  } catch {
    return false;
  }
}

export function setPref(key: Key, value: boolean): void {
  try {
    if (value) window.localStorage.setItem(KEYS[key], "1");
    else window.localStorage.removeItem(KEYS[key]);
  } catch {
    // Storage blocked: the change lasts until the page is closed.
    memory.set(key, value);
  }
  listeners.forEach((listener) => listener());
}

const memory = new Map<Key, boolean>();

export function getPref(key: Key): boolean {
  return memory.get(key) ?? read(key);
}

export function usePref(key: Key): boolean {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => getPref(key),
  );
}

/** Used by "Erase everything" so nothing about this person is left behind. */
export function clearPrefs(): void {
  memory.clear();
  for (const name of Object.values(KEYS)) {
    try {
      window.localStorage.removeItem(name);
    } catch {
      // Nothing stored.
    }
  }
  listeners.forEach((listener) => listener());
}
