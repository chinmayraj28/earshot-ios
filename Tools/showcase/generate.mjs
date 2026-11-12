#!/usr/bin/env node
// Builds the README / portfolio showcase images in docs/showcase/ from the real app
// screenshots in docs/screenshots/. Each image is an HTML page rendered to PNG with the
// Chromium that Playwright already installed for the web client's tests.
//
//   node Tools/showcase/generate.mjs            # build everything
//   node Tools/showcase/generate.mjs hero tiles # build only some outputs
//
// To change which screenshot appears where, edit CONFIG below. Nothing else should need
// to change when new screens are added.

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { readFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// ────────────────────────────────────────────────────────────────────────────────────
// CONFIG: which screenshot goes where. Paths are relative to docs/screenshots/.
// Phones in a hero are listed left to right; the middle one is the front, largest phone.
// ────────────────────────────────────────────────────────────────────────────────────
const CONFIG = {
  hero: {
    // Dark card, dark-mode screens only.
    dark: ["onboarding-welcome-dark.png", "home-dark.png", "chat-dark.png", "incoming-request-dark.png", "contact-details-dark.png"],
    // Warm paper card, light-mode screens only.
    light: ["onboarding-welcome.png", "home-light.png", "chat.png", "incoming-request.png", "contact-details.png"],
  },
  web: {
    theme: "dark", // "dark" or "light": card, window frame and screenshots
    address: "localhost:5183",
    wide: { dark: "web/chat-wide-dark.png", light: "web/chat-wide-light.png" },
    // A phone-width screenshot of the same web client, shown in a phone overlapping a corner.
    // Set to null to leave it out.
    narrow: { dark: "web/home-narrow-dark.png", light: "web/home-narrow-light.png" },
  },
  // One card per entry, written to docs/showcase/tile-<name>.png.
  // kind "web" is for a phone-width web screenshot: it gets a browser address bar instead
  // of a status bar. theme ("light"/"dark") only matters for kind "web".
  tiles: [
    { name: "home", caption: "Home", src: "home-light.png" },
    { name: "chat", caption: "Chat", src: "chat.png" },
    { name: "request", caption: "Request", src: "incoming-request.png" },
    { name: "nearby", caption: "Nearby", src: "nearby-waiting.png" },
    { name: "contact", caption: "Safety code", src: "contact-details.png" },
    { name: "notification", caption: "Notification", src: "notification-banner.png" },
    { name: "onboarding", caption: "Welcome", src: "onboarding-welcome.png" },
    { name: "settings", caption: "Settings", src: "settings.png" },
    { name: "web-chat", caption: "Web version", src: "web/chat-narrow-light.png", kind: "web", theme: "light" },
    { name: "photos", caption: "Photos & formatting", src: "chat-formatting-and-photo.png" },
    { name: "relay", caption: "Travels through friends", src: "relay-delivered.png" },
  ],
  social: {
    title: "Earshot",
    tagline: "Text the people near you when the network is gone.",
    detail: "Bluetooth only. No internet, no server.",
    phones: ["home-light.png", "chat-dark.png", "incoming-request.png"], // left, front, right
  },
};

// ────────────────────────────────────────────────────────────────────────────────────
// Paths and colours
// ────────────────────────────────────────────────────────────────────────────────────
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const SHOTS = join(ROOT, "docs/screenshots");
const OUT = join(ROOT, "docs/showcase");
const ICON = join(ROOT, "Earshot/Assets.xcassets/AppIcon.appiconset/AppIcon.png");
const ROUNDED_FONT = "/System/Library/Fonts/SFNSRounded.ttf"; // macOS only; other systems fall back to system-ui

// Earshot palette (Earshot/Design/Palette.swift).
const C = {
  paper: "#F5EFE6",
  surface: "#FFFBF5",
  ink: "#121110",
  inkText: "#1C1916",
  inkSecondaryLight: "#5F574D",
  inkSecondaryDark: "#A89F94",
  textDark: "#F2ECE4",
  ember: "#B4421C",
  emberBright: "#FF8A5C",
  signal: "#E2603A",
  signalDark: "#FF7A4D",
};

// iOS screenshot geometry (simulator captures, 1206 x 2622).
const SCREEN_RATIO = 2622 / 1206;
// The camera pill as drawn by the simulator, as fractions of the screenshot. The frame
// draws its own pill at exactly this spot, so screens captured with and without it match.
const PILL = { left: 415 / 1206, top: 42 / 2622, width: 376 / 1206, height: 110 / 2622 };

// ────────────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────────────
const dataCache = new Map();
function dataUri(file, mime = "image/png") {
  if (!dataCache.has(file)) {
    if (!existsSync(file)) throw new Error(`Missing file: ${file}`);
    dataCache.set(file, `data:${mime};base64,${readFileSync(file).toString("base64")}`);
  }
  return dataCache.get(file);
}
const shot = (name) => dataUri(join(SHOTS, name));

function fontFace() {
  if (!existsSync(ROUNDED_FONT)) return "";
  return `@font-face { font-family: "EarshotRounded"; src: url("${dataUri(ROUNDED_FONT, "font/ttf")}"); font-weight: 100 900; }`;
}

const BASE_CSS = () => `
  ${fontFace()}
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { background: transparent; }
  body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; -webkit-font-smoothing: antialiased; }
  .rounded { font-family: "EarshotRounded", ui-rounded, system-ui, sans-serif; }

  /* ── Generic phone: rounded body, thin bezel, soft shadow, subtle edge highlight ── */
  .phone {
    position: absolute;
    border-radius: var(--outer-r);
    padding: var(--bezel);
    background: linear-gradient(150deg, #4a4542 0%, #1b1917 18%, #0c0b0a 55%, #24211f 100%);
    box-shadow:
      inset 0 0 0 1px rgba(255,255,255,0.10),
      inset 0 0 0 2.5px rgba(0,0,0,0.9),
      var(--phone-shadow);
  }
  .phone::after { /* thin highlight on the rim */
    content: ""; position: absolute; inset: 1px; border-radius: calc(var(--outer-r) - 1px);
    box-shadow: inset 0 1px 0 rgba(255,255,255,0.18), inset 0 -1px 0 rgba(255,255,255,0.05);
    pointer-events: none;
  }
  .screen {
    position: relative; width: 100%; height: 100%;
    border-radius: var(--inner-r); overflow: hidden;
    background: #000;
    /* forces a real clip on rounded corners under 3D transforms */
    -webkit-mask-image: -webkit-radial-gradient(white, black);
    isolation: isolate;
  }
  .screen img { display: block; width: 100%; height: 100%; object-fit: cover; object-position: top; }
  .screen .inset { position: absolute; left: 0; right: 0; top: 0; }
  .screen .pill {
    position: absolute; background: #000; border-radius: 999px;
    left: ${PILL.left * 100}%; width: ${PILL.width * 100}%;
    top: ${PILL.top * 100}%; height: ${PILL.height * 100}%;
  }
  .screen .dot { position: absolute; left: 50%; border-radius: 50%; background: #000; transform: translateX(-50%); }
`;

/**
 * A phone at its own position.
 * width: total body width in CSS px. style: extra inline CSS (position, transform...).
 * variant "ios": the screenshot already contains a status bar; a pill covers the camera area.
 * variant "web": a phone-width web screenshot (no status bar of its own) shown under a
 *   small, generic browser address bar, as the web client looks in a phone's browser.
 */
function phone({ src, width, style = "", variant = "ios", shadow = "dark", theme = "dark", address = CONFIG.web.address }) {
  const bezel = Math.max(4, width * 0.034);
  const screenW = width - bezel * 2;
  const innerR = screenW * 0.135;
  const outerR = innerR + bezel;
  const screenH = screenW * SCREEN_RATIO;
  const height = screenH + bezel * 2;
  const s = width / 260; // shadows scale with phone size
  const shadows = {
    dark: `0 ${40 * s}px ${70 * s}px -${12 * s}px rgba(0,0,0,0.75), 0 ${14 * s}px ${28 * s}px rgba(0,0,0,0.45)`,
    light: `0 ${36 * s}px ${64 * s}px -${14 * s}px rgba(60,30,10,0.38), 0 ${10 * s}px ${22 * s}px rgba(60,30,10,0.20)`,
  };
  let inner;
  if (variant === "web") {
    // A phone browser: a small round camera, then an address bar, then the page.
    const dark = theme === "dark";
    const strip = screenH * 0.1;
    const pillH = strip * 0.4;
    const fs = pillH * 0.48;
    inner = `<div style="position:absolute;inset:0;background:${dark ? "#121110" : C.paper}"></div>
      <div style="position:absolute;left:0;right:0;top:0;height:${strip}px;background:${dark ? "#1d1b19" : "#ECE5DA"};
          border-bottom:1px solid ${dark ? "rgba(255,255,255,0.06)" : "rgba(60,30,10,0.08)"}"></div>
      <span class="dot" style="top:${strip * 0.13}px;width:${strip * 0.2}px;height:${strip * 0.2}px"></span>
      <div style="position:absolute;left:12%;right:12%;top:${strip - pillH - strip * 0.12}px;height:${pillH}px;border-radius:999px;
          background:${dark ? "#2b2724" : "#F8F3EB"};color:${dark ? C.inkSecondaryDark : C.inkSecondaryLight};
          display:flex;align-items:center;justify-content:center;font-size:${fs}px;letter-spacing:0.01em">${address}</div>
      <img src="${src}" style="position:absolute;top:${strip}px;height:${screenH - strip}px;object-fit:cover;object-position:top">`;
  } else {
    inner = `<img src="${src}"><span class="pill"></span>`;
  }
  return `<div class="phone" style="--bezel:${bezel}px;--outer-r:${outerR}px;--inner-r:${innerR}px;--phone-shadow:${shadows[shadow]};width:${width}px;height:${height}px;${style}">
    <div class="screen">${inner}</div>
  </div>`;
}
phone.height = (width) => {
  const bezel = Math.max(4, width * 0.034);
  return (width - bezel * 2) * SCREEN_RATIO + bezel * 2;
};

/** Concentric Earshot rings as an inline SVG, centred at (cx, cy). */
function rings({ w, h, cx, cy, color, radii, opacity, width = 1.5 }) {
  const circles = radii
    .map((r, i) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${color}" stroke-width="${width}" stroke-opacity="${opacity * (1 - i / (radii.length + 1))}"/>`)
    .join("");
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="position:absolute;inset:0">${circles}</svg>`;
}

/** Card background: warm ink (dark) or paper (light), an ember glow and faint rings. */
function backdrop({ w, h, theme, cx = w / 2, cy = h * 0.52, ringScale = 1 }) {
  const dark = theme === "dark";
  const base = dark
    ? `radial-gradient(ellipse ${w * 0.55}px ${h * 0.6}px at ${cx}px ${cy}px, rgba(226,96,58,0.30), rgba(180,66,28,0.10) 55%, rgba(0,0,0,0) 100%),
       radial-gradient(ellipse ${w * 0.9}px ${h * 0.9}px at ${cx}px ${h * 1.05}px, rgba(255,122,77,0.10), rgba(0,0,0,0) 70%),
       linear-gradient(180deg, #1a1715 0%, #121110 60%, #0e0d0c 100%)`
    : `radial-gradient(ellipse ${w * 0.55}px ${h * 0.6}px at ${cx}px ${cy}px, rgba(226,96,58,0.16), rgba(226,96,58,0.05) 55%, rgba(0,0,0,0) 100%),
       linear-gradient(180deg, #F8F3EB 0%, #F5EFE6 55%, #EFE6DA 100%)`;
  const r = Math.max(w, h) * ringScale;
  const svg = rings({
    w, h, cx, cy,
    color: dark ? C.signalDark : C.signal,
    radii: [0.16, 0.25, 0.35, 0.46, 0.58].map((f) => f * r),
    opacity: dark ? 0.11 : 0.13,
  });
  return `<div style="position:absolute;inset:0;background:${base}"></div>${svg}`;
}

function page({ w, h, radius = 0, body, css = "" }) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${BASE_CSS()}
    .card { position: relative; width: ${w}px; height: ${h}px; overflow: hidden; border-radius: ${radius}px; isolation: isolate; }
    ${css}</style></head><body><div class="card">${body}</div></body></html>`;
}

// ────────────────────────────────────────────────────────────────────────────────────
// Compositions
// ────────────────────────────────────────────────────────────────────────────────────

/** Five phones fanned out: front one upright in the centre, the others smaller and turned. */
function fan({ w, h, srcs, theme, centreWidth, slots }) {
  const cx = w / 2;
  const shadow = theme === "dark" ? "dark" : "light";
  const phones = srcs.map((src, i) => {
    const slot = slots[i];
    const pw = centreWidth * slot.scale;
    const ph = phone.height(pw);
    const left = cx + slot.x - pw / 2;
    const top = h / 2 - ph / 2 + (slot.y || 0);
    const t = `perspective(${slot.perspective || 1400}px) rotateY(${slot.rotate}deg)`;
    return phone({
      src: shot(src), width: pw, shadow,
      style: `left:${left}px;top:${top}px;z-index:${slot.z};transform:${t};transform-origin:50% 50%`,
    });
  });
  return phones.join("");
}

// Left to right. x is the horizontal offset of each phone's centre from the card centre.
// rotate > 0 turns the phone's right edge away; side phones are turned outward, so their
// inner edges tuck behind their neighbours.
const FAN_SLOTS = [
  { x: -410, scale: 0.70, rotate: 26, z: 1 },
  { x: -222, scale: 0.85, rotate: 18, z: 2 },
  { x: 0, scale: 1, rotate: 0, z: 3 },
  { x: 222, scale: 0.85, rotate: -18, z: 2 },
  { x: 410, scale: 0.70, rotate: -26, z: 1 },
];

function heroPage(theme) {
  const w = 1200, h = 675;
  const srcs = CONFIG.hero[theme];
  return page({
    w, h, radius: 28,
    body: backdrop({ w, h, theme, cy: h * 0.5, ringScale: 0.95 }) +
      fan({ w, h, srcs, theme, centreWidth: 262, slots: FAN_SLOTS }),
  });
}

/** A plain, generic browser window: rounded, three neutral dots, an address pill. */
function browserWindow({ src, width, theme, address, style = "" }) {
  const dark = theme === "dark";
  const bar = 34;
  const imgH = width * (800 / 1280);
  return `<div style="position:absolute;width:${width}px;height:${imgH + bar}px;border-radius:12px;overflow:hidden;
      background:${dark ? "#1f1c1a" : "#ECE5DA"};
      box-shadow: 0 0 0 1px ${dark ? "rgba(255,255,255,0.09)" : "rgba(60,30,10,0.10)"}, 0 40px 80px -20px rgba(0,0,0,${dark ? 0.75 : 0.35}), 0 14px 30px rgba(0,0,0,${dark ? 0.4 : 0.12});${style}">
    <div style="height:${bar}px;display:flex;align-items:center;padding:0 14px;gap:7px;position:relative;
        border-bottom:1px solid ${dark ? "rgba(255,255,255,0.06)" : "rgba(60,30,10,0.08)"}">
      ${[0, 1, 2].map(() => `<span style="width:11px;height:11px;border-radius:50%;background:${dark ? "#3d3834" : "#CFC5B8"}"></span>`).join("")}
      <div style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:${Math.min(320, width * 0.36)}px;height:22px;border-radius:999px;
          background:${dark ? "#2b2724" : "#F8F3EB"};display:flex;align-items:center;justify-content:center;gap:6px;
          font-size:11.5px;letter-spacing:0.01em;color:${dark ? "#A89F94" : "#5F574D"}">
        <svg width="9" height="11" viewBox="0 0 9 11"><rect x="0.5" y="4.5" width="8" height="6" rx="1.5" fill="currentColor"/><path d="M2.3 4.6V3.2a2.2 2.2 0 0 1 4.4 0v1.4" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>
        ${address}
      </div>
    </div>
    <img src="${src}" style="display:block;width:${width}px;height:${imgH}px">
  </div>`;
}

function webPage() {
  const { theme, address, wide, narrow } = CONFIG.web;
  const w = 1200, h = 750;
  const winW = narrow ? 850 : 960;
  const winH = winW * (800 / 1280) + 34;
  // The phone only overlaps the window's empty padding and its lower-right corner, never the messages.
  const winLeft = narrow ? 62 : (w - winW) / 2;
  const winTop = narrow ? 64 : (h - winH) / 2;
  let body = backdrop({ w, h, theme, cx: w * 0.5, cy: h * 0.5, ringScale: 0.9 });
  body += browserWindow({ src: shot(wide[theme]), width: winW, theme, address, style: `left:${winLeft}px;top:${winTop}px` });
  if (narrow) {
    const pw = 240;
    const ph = phone.height(pw);
    body += phone({
      src: shot(narrow[theme]), width: pw, variant: "web", theme, address, shadow: "dark",
      style: `left:${winLeft + winW - 14}px;top:${h - ph - 40}px;z-index:5`,
    });
  }
  return page({ w, h, radius: 28, body });
}

/** One tile: caption at the top, a phone cropped by the card's bottom edge. */
function tilePage(tile) {
  const w = 420, h = 520;
  const theme = "dark";
  let body = backdrop({ w, h, theme, cy: h * 0.62, ringScale: 1.05 });
  body += `<div style="position:absolute;top:26px;left:0;right:0;text-align:center;font-size:12.5px;font-weight:600;letter-spacing:0.22em;
      text-transform:uppercase;color:${C.inkSecondaryDark}">${tile.caption}</div>`;
  const pw = 252;
  body += phone({
    src: shot(tile.src), width: pw, shadow: "dark",
    variant: tile.kind === "web" ? "web" : "ios", theme: tile.theme || "light",
    style: `left:${(w - pw) / 2}px;top:70px`,
  });
  return page({ w, h, radius: 22, body });
}

function socialPage() {
  const { title, tagline, detail, phones: srcs } = CONFIG.social;
  const w = 1280, h = 640;
  let body = backdrop({ w, h, theme: "dark", cx: 960, cy: 330, ringScale: 0.75 });
  body += `<div style="position:absolute;left:84px;top:0;bottom:0;width:560px;display:flex;flex-direction:column;justify-content:center;">
      <div style="display:flex;align-items:center;gap:26px;">
        <img src="${dataUri(ICON)}" style="width:104px;height:104px;border-radius:24px;box-shadow:0 0 0 1px rgba(255,255,255,0.08),0 14px 30px rgba(0,0,0,0.5)">
        <div class="rounded" style="font-size:104px;font-weight:700;color:${C.textDark};letter-spacing:-0.02em;line-height:1">${title}</div>
      </div>
      <div style="margin-top:38px;font-size:44px;line-height:1.18;font-weight:600;color:${C.textDark};letter-spacing:-0.01em">${tagline}</div>
      <div style="margin-top:22px;font-size:27px;line-height:1.3;color:${C.inkSecondaryDark}">${detail}</div>
    </div>`;
  const cx = 960;
  const slots = [
    { x: -150, scale: 0.84, rotate: 16, z: 1, y: 40 },
    { x: 0, scale: 1, rotate: 0, z: 3, y: 60 },
    { x: 150, scale: 0.84, rotate: -16, z: 1, y: 40 },
  ];
  const centreWidth = 270;
  body += srcs.map((src, i) => {
    const s = slots[i];
    const pw = centreWidth * s.scale;
    const ph = phone.height(pw);
    return phone({
      src: shot(src), width: pw, shadow: "dark",
      style: `left:${cx + s.x - pw / 2}px;top:${h / 2 - ph / 2 + s.y}px;z-index:${s.z};transform:perspective(1400px) rotateY(${s.rotate}deg)`,
    });
  }).join("");
  return page({ w, h, body });
}

// ────────────────────────────────────────────────────────────────────────────────────
// Rendering
// ────────────────────────────────────────────────────────────────────────────────────
const JOBS = {
  hero: () => [
    { file: "hero.png", html: heroPage("dark"), w: 1200, h: 675, scale: 4, supersample: 2 },
    { file: "hero-light.png", html: heroPage("light"), w: 1200, h: 675, scale: 4, supersample: 2 },
  ],
  web: () => [{ file: "web.png", html: webPage(), w: 1200, h: 750, scale: 4 }],
  tiles: () => CONFIG.tiles.map((t) => ({ file: `tile-${t.name}.png`, html: tilePage(t), w: 420, h: 520, scale: 3 })),
  social: () => [{ file: "social-preview.png", html: socialPage(), w: 1280, h: 640, scale: 2, supersample: 2, opaque: true }],
};

async function main() {
  const wanted = process.argv.slice(2);
  const names = wanted.length ? wanted : Object.keys(JOBS);
  for (const n of names) if (!JOBS[n]) throw new Error(`Unknown output "${n}". Choose from: ${Object.keys(JOBS).join(", ")}`);

  const requireFromWeb = createRequire(join(ROOT, "web/package.json"));
  const { chromium } = requireFromWeb("playwright");
  mkdirSync(OUT, { recursive: true });

  const browser = await chromium.launch();
  try {
    for (const name of names) {
      for (const job of JOBS[name]()) {
        const context = await browser.newContext({ viewport: { width: job.w, height: job.h }, deviceScaleFactor: job.scale * (job.supersample || 1) });
        const pg = await context.newPage();
        await pg.setContent(job.html, { waitUntil: "load" });
        await pg.evaluate(() => document.fonts.ready);
        const out = join(OUT, job.file);
        const card = pg.locator(".card");
        await card.screenshot({ path: out, omitBackground: !job.opaque });
        // Tilted phones come out slightly soft when drawn at their final size. Drawing them
        // larger and shrinking the picture afterwards (macOS `sips`) gives sharper text.
        if (job.supersample && process.platform === "darwin") {
          execFileSync("sips", ["--resampleWidth", String(job.w * job.scale), out], { stdio: "ignore" });
        }
        await context.close();
        console.log(`${job.file.padEnd(24)} ${(statSync(out).size / 1024).toFixed(0).padStart(5)} KB`);
      }
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
