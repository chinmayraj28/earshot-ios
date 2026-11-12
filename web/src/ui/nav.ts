/**
 * In-app navigation kept in the browser's history state, so the Back button (and Android's
 * back gesture) works, but the address bar never changes. Contact names and message text are
 * never put in the URL; only an opaque contact ID lives in history.state.
 */
import { useCallback, useEffect, useState } from "react";
import type { ContactID } from "../engine/api";

export type View =
  | { kind: "home" }
  | { kind: "chat"; id: ContactID }
  | { kind: "contact"; id: ContactID }
  | { kind: "settings" }
  | { kind: "howItWorks" }
  | { kind: "privacy" };

interface HistoryEntry {
  earshot: true;
  view: View;
  /** How many in-app steps lie behind this one. 0 means Back would leave Earshot. */
  depth: number;
}

const HOME: View = { kind: "home" };
/** Set while history.go(-n) is unwinding to the first entry, which then becomes "home". */
let unwindingToHome = false;

function currentEntry(): HistoryEntry | null {
  const state = window.history.state as Partial<HistoryEntry> | null;
  return state && state.earshot && state.view ? (state as HistoryEntry) : null;
}

export function useNavigation() {
  const [view, setView] = useState<View>(() => currentEntry()?.view ?? HOME);

  useEffect(() => {
    if (!currentEntry()) window.history.replaceState({ earshot: true, view: HOME, depth: 0 } satisfies HistoryEntry, "");
    const onPop = () => {
      if (unwindingToHome) {
        unwindingToHome = false;
        window.history.replaceState({ earshot: true, view: HOME, depth: 0 } satisfies HistoryEntry, "");
        setView(HOME);
        return;
      }
      setView(currentEntry()?.view ?? HOME);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  const navigate = useCallback((next: View, options: { replace?: boolean } = {}) => {
    const entry = currentEntry();
    const depth = entry?.depth ?? 0;
    if (options.replace) {
      window.history.replaceState({ earshot: true, view: next, depth } satisfies HistoryEntry, "");
    } else {
      window.history.pushState({ earshot: true, view: next, depth: depth + 1 } satisfies HistoryEntry, "");
    }
    setView(next);
  }, []);

  /** Goes back one in-app step; if this is the first page Earshot opened on, goes home instead. */
  const back = useCallback(
    (fallback: View = HOME) => {
      if ((currentEntry()?.depth ?? 0) > 0) window.history.back();
      else navigate(fallback, { replace: true });
    },
    [navigate],
  );

  /** Returns to the conversation list, unwinding history so Back doesn't revisit removed screens. */
  const home = useCallback(() => {
    const depth = currentEntry()?.depth ?? 0;
    if (depth > 0) {
      unwindingToHome = true;
      window.history.go(-depth);
    } else navigate(HOME, { replace: true });
  }, [navigate]);

  return { view, navigate, back, home };
}

export function sameView(a: View, b: View): boolean {
  return a.kind === b.kind && ("id" in a ? a.id : null) === ("id" in b ? b.id : null);
}
