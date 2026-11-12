/*
 * Earshot's service worker. Its only job is to let the app open with no network at all.
 *
 * How it works, in plain words:
 * 1. On install it downloads the page (index.html), reads which script and style files the
 *    page needs (Vite gives them hashed names such as /assets/index-3f9a.js), and saves the
 *    page, those files, the icons and the manifest in a cache.
 * 2. Every later visit is answered from that cache first, so the app opens instantly even in
 *    a train tunnel. In the background it asks the server for a newer page; if there is one,
 *    it saves the new page's files first and only then swaps the page, so the cache never
 *    points at files it does not have.
 * 3. It never talks to any server other than the one this app came from, and it never sees
 *    messages: those live in the browser's storage, not in network requests.
 *
 * Only registered in production builds (see src/main.tsx).
 */
const CACHE = "earshot-shell-v1";
const SCOPE = new URL(self.registration.scope);
const PAGE = new URL("./", SCOPE).href;
const STATIC_FILES = [
  "manifest.webmanifest",
  "icons/icon-32.png",
  "icons/icon-64.png",
  "icons/icon-180.png",
  "icons/icon-192.png",
  "icons/icon-512.png",
].map((path) => new URL(path, SCOPE).href);

/** Finds every same-site script, style, icon and preload the page refers to. */
function filesNamedIn(html) {
  const found = new Set();
  const pattern = /(?:src|href)="([^"]+)"/g;
  let match;
  while ((match = pattern.exec(html))) {
    const url = new URL(match[1], SCOPE);
    if (url.origin === SCOPE.origin && url.href !== PAGE) found.add(url.href);
  }
  return [...found];
}

/** Downloads the page and everything it needs, then stores them, page last. */
async function saveShell() {
  const response = await fetch(PAGE, { cache: "no-cache" });
  if (!response.ok) throw new Error("Page download failed");
  const html = await response.clone().text();
  const cache = await caches.open(CACHE);
  const files = [...new Set([...filesNamedIn(html), ...STATIC_FILES])];
  await Promise.all(
    files.map(async (file) => {
      if (await cache.match(file, { ignoreVary: true })) return; // Hashed names never change content.
      const fileResponse = await fetch(file, { cache: "no-cache" });
      if (fileResponse.ok) await cache.put(file, fileResponse);
    }),
  );
  await cache.put(PAGE, response);
}

self.addEventListener("install", (event) => {
  event.waitUntil(saveShell().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(names.filter((name) => name !== CACHE).map((name) => caches.delete(name)));
      await self.clients.claim();
    })(),
  );
});

/** The page can send the list of files it actually loaded, so lazily loaded chunks are kept too. */
self.addEventListener("message", (event) => {
  const data = event.data;
  if (!data || data.type !== "cache-files" || !Array.isArray(data.files)) return;
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      for (const file of data.files) {
        const url = new URL(String(file), SCOPE);
        if (url.origin !== SCOPE.origin || url.pathname.startsWith("/@")) continue;
        if (await cache.match(url.href, { ignoreVary: true })) continue;
        try {
          const response = await fetch(url.href);
          if (response.ok) await cache.put(url.href, response);
        } catch {
          // Offline right now; the file will be saved on a later visit.
        }
      }
    })(),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== SCOPE.origin) return; // Never touch anything from another site.

  if (request.mode === "navigate") {
    // Answer from the cache straight away, and look for a newer version in the background.
    event.respondWith(
      (async () => {
        const cached = await caches.match(PAGE, { ignoreVary: true });
        const refresh = saveShell().catch(() => undefined);
        if (cached) {
          event.waitUntil(refresh);
          return cached;
        }
        try {
          return await fetch(request);
        } catch {
          return new Response("Earshot is offline and has not been saved on this device yet. Open it once with a connection.", {
            status: 503,
            headers: { "Content-Type": "text/plain; charset=utf-8" },
          });
        }
      })(),
    );
    return;
  }

  event.respondWith(
    (async () => {
      // ignoreVary: servers often send "Vary: Origin", and module scripts are requested with an
      // Origin header that the saved copy was fetched without; the file is the same either way.
      const cached = await caches.match(request, { ignoreVary: true });
      if (cached) return cached;
      const response = await fetch(request);
      if (response.ok && url.pathname.includes("/assets/")) {
        const cache = await caches.open(CACHE);
        await cache.put(request, response.clone());
      }
      return response;
    })(),
  );
});

/** Clicking a notification shown through the service worker (Android) opens that chat. */
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      const client = windows[0];
      if (client) {
        await client.focus();
        client.postMessage({ type: "open-chat", tag: event.notification.tag });
      } else {
        await self.clients.openWindow(PAGE);
      }
    })(),
  );
});
