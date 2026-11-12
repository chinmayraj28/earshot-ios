import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./ui/App";
import "./ui/styles.css";

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}

// The service worker keeps a copy of the app so it opens with no network. Only in real builds:
// during development it would serve stale files.
if (import.meta.env.PROD && "serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("/sw.js", { scope: "/" })
      .then(async () => {
        const registration = await navigator.serviceWorker.ready;
        // Also save any file this visit loaded after the page itself (for example a split-off chunk).
        const files = performance
          .getEntriesByType("resource")
          .map((entry) => entry.name)
          .filter((name) => name.startsWith(window.location.origin));
        registration.active?.postMessage({ type: "cache-files", files });
      })
      .catch(() => {
        // Without a service worker the app still works; it just needs the network to open.
      });
  });
}
