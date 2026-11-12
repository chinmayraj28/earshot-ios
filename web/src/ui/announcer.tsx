/**
 * One shared "polite" live region. Screens call announce("Connected to Sam") and screen
 * readers read it out without moving focus. Used for new messages and status changes.
 */
import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from "react";

const AnnounceContext = createContext<(text: string) => void>(() => undefined);

export function AnnouncerProvider({ children }: { children: ReactNode }) {
  const [text, setText] = useState("");
  const timer = useRef<number | undefined>(undefined);
  const announce = useCallback((next: string) => {
    window.clearTimeout(timer.current);
    // Clearing first makes the same sentence get read again if it repeats.
    setText("");
    timer.current = window.setTimeout(() => setText(next), 60);
  }, []);
  return (
    <AnnounceContext.Provider value={announce}>
      {children}
      <div className="visually-hidden" role="status" aria-live="polite" aria-atomic="true" data-testid="announcer">
        {text}
      </div>
    </AnnounceContext.Provider>
  );
}

export function useAnnounce(): (text: string) => void {
  return useContext(AnnounceContext);
}
