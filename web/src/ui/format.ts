/** Small text and time helpers shared by the screens. */
import { Limits, type LinkState, type Message, type RequestFailure } from "../engine/api";

/**
 * Cleans a display name exactly like the phone does (Limits.sanitizedName in EarshotKit):
 * drops control characters and line breaks, trims, turns runs of spaces into one space,
 * keeps at most 32 characters and at most 96 bytes.
 * Example: "  Jensen   Huang \n" becomes "Jensen Huang".
 */
export function sanitizeName(raw: string): string {
  // Swift's CharacterSet.controlCharacters is Unicode categories Cc and Cf; newlines adds Zl and Zp.
  const withoutControls = raw.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, "");
  const collapsed = withoutControls.split(" ").filter(Boolean).join(" ");
  let chars = graphemes(collapsed).slice(0, Limits.maxNameLength);
  const encoder = new TextEncoder();
  while (chars.length > 0 && encoder.encode(chars.join("")).length > Limits.maxNameBytes) chars = chars.slice(0, -1);
  return chars.join("");
}

/** Splits text into the characters a person sees (so an accented letter or flag counts as one). */
export function graphemes(text: string): string[] {
  if (typeof Intl !== "undefined" && "Segmenter" in Intl) {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    return Array.from(segmenter.segment(text), (part) => part.segment);
  }
  return Array.from(text);
}

/** "Jensen Huang" -> "MO", "tomás" -> "T". Same rule as the phone's Avatar. */
export function initials(name: string): string {
  const words = name.split(/\s+/).filter(Boolean).slice(0, 2);
  const letters = words.map((word) => (graphemes(word)[0] ?? "").toLocaleUpperCase()).join("");
  return letters || "?";
}

/** "Jensen Huang" -> "Jensen". Keeps status lines short and personal. */
export function firstName(name: string): string {
  return name.split(/\s+/).filter(Boolean)[0] ?? name;
}

/**
 * Which of the six avatar tones a name gets. This is the phone's "djb2" hash over Unicode
 * scalars with 64-bit wrap-around, so a contact has the same colour on both devices.
 */
export function avatarTone(name: string): number {
  let hash = 5381n;
  const mask = (1n << 64n) - 1n;
  for (const ch of name) hash = (hash * 33n + BigInt(ch.codePointAt(0) ?? 0)) & mask;
  return Number(hash % 6n);
}

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" });
const weekdayFormat = new Intl.DateTimeFormat(undefined, { weekday: "long" });
const shortDateFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" });
const longDateFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "long", year: "numeric" });

export function startOfDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function daysAgo(ms: number, now = Date.now()): number {
  return Math.round((startOfDay(now) - startOfDay(ms)) / 86_400_000);
}

export function formatTime(ms: number): string {
  return timeFormat.format(ms);
}

/** For conversation rows: "04:25" today, "Yesterday", "Tuesday" this week, otherwise "3 Nov". */
export function formatListTime(ms: number, now = Date.now()): string {
  const days = daysAgo(ms, now);
  if (days <= 0) return timeFormat.format(ms);
  if (days === 1) return "Yesterday";
  if (days < 7) return weekdayFormat.format(ms);
  return shortDateFormat.format(ms);
}

/** For the separators in a chat: "Today, 04:20", "Yesterday, 18:02", "3 November 2026, 09:15". */
export function formatDaySeparator(ms: number, now = Date.now()): string {
  const days = daysAgo(ms, now);
  const time = timeFormat.format(ms);
  if (days <= 0) return `Today, ${time}`;
  if (days === 1) return `Yesterday, ${time}`;
  if (days < 7) return `${weekdayFormat.format(ms)}, ${time}`;
  return `${longDateFormat.format(ms)}, ${time}`;
}

export function formatLongDate(ms: number): string {
  return longDateFormat.format(ms);
}

export function linkLabel(link: LinkState): string {
  switch (link) {
    case "connected":
      return "Connected";
    case "connecting":
      return "Connecting…";
    case "outOfRange":
      return "Not connected";
  }
}

/** One line for a conversation row's preview. */
export function previewText(message: Message | null): string {
  if (!message) return "No messages yet. Say hello.";
  if (message.direction === "outgoing") {
    if (message.status === "waiting") return `Waiting: ${message.text}`;
    if (message.status === "failed") return `Not delivered: ${message.text}`;
    return `You: ${message.text}`;
  }
  return message.text;
}

/** Plain reasons for a request that did not work out, with what to try next. */
export function requestFailureText(failure: RequestFailure, name: string): string {
  const first = firstName(name);
  switch (failure) {
    case "noAnswer":
      return `No answer. ${first} may have declined, missed it or moved away. Check that Earshot is open on their phone, then try again.`;
    case "connectionLost":
      return "The connection dropped while setting up. Move a little closer and try again.";
    case "verificationFailed":
      return "Earshot couldn't confirm who this is, so nothing was shared.";
    case "incompatibleVersion":
      return `Your versions of Earshot don't match. ${first} may need to update Earshot on their phone.`;
  }
}

export type FindFailure = "notEarshot" | "unreachable" | "unavailable";

export function findFailureText(reason: FindFailure): { title: string; detail: string } {
  switch (reason) {
    case "notEarshot":
      return {
        title: "That device isn't running Earshot",
        detail: "It didn't answer like a phone with Earshot open. Try again and pick the phone that has Earshot open on its screen.",
      };
    case "unreachable":
      return {
        title: "Couldn't reach that phone",
        detail: "Move closer, check that Earshot is still open on the phone's screen, and try again.",
      };
    case "unavailable":
      // The engine also answers "unavailable" when the picked phone belongs to a blocked contact.
      return {
        title: "Couldn't connect to that phone",
        detail:
          "Check that Bluetooth is turned on here, then try again. If you picked someone you blocked, unblock them in their contact details first.",
      };
  }
}

/** True when two messages sit close enough together to share one bubble group. */
export function sameGroup(a: Message, b: Message): boolean {
  return a.direction === b.direction && b.timestamp - a.timestamp < 5 * 60_000 && startOfDay(a.timestamp) === startOfDay(b.timestamp);
}
