/**
 * Text rules shared with the phone (Models.swift `Limits`).
 *
 * Swift counts "characters" as grapheme clusters: "👋🏽" is one character, not four
 * UTF-16 units. `Intl.Segmenter` counts the same way, so a 2,000-character message is
 * accepted by both apps or by neither.
 */
import { Limits } from "./api";

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), (s) => s.segment);
}

export function graphemeCount(text: string): number {
  let n = 0;
  for (const _ of segmenter.segment(text)) n++;
  return n;
}

/** Swift's `.whitespacesAndNewlines`: space separators, tab, line breaks. */
const EDGE_SPACE = /^[\p{Zs}\t\n\v\f\r\u0085\u2028\u2029]+|[\p{Zs}\t\n\v\f\r\u0085\u2028\u2029]+$/gu;

/** Unicode "control" (Cc) and "format" (Cf) characters plus line breaks: what `sanitizedName` removes. */
const NAME_JUNK = /[\p{Cc}\p{Cf}\n\v\f\r\u0085\u2028\u2029]/gu;

/** Replaces lone UTF-16 surrogates (which Swift strings cannot hold) with U+FFFD. */
export function wellFormed(text: string): string {
  return text.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "�");
}

export function isWellFormed(text: string): boolean {
  return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(text);
}

/**
 * Cleans a name typed here or received from a phone, exactly like `Limits.sanitizedName`:
 * removes control and format characters and line breaks, squeezes runs of spaces, keeps at most
 * 32 characters and at most 96 bytes of UTF-8.
 * Example: "  Maya\n  Okafor​ " becomes "Maya Okafor".
 */
export function sanitizedName(raw: string): string {
  const collapsed = wellFormed(raw)
    .replace(NAME_JUNK, "")
    .split(" ")
    .filter((part) => part.length > 0)
    .join(" ");
  const chars = graphemes(collapsed).slice(0, Limits.maxNameLength);
  const encoder = new TextEncoder();
  while (chars.length > 0 && encoder.encode(chars.join("")).length > Limits.maxNameBytes) chars.pop();
  return chars.join("");
}

/** Trims spaces and line breaks at both ends, as Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimmed(text: string): string {
  return wellFormed(text).replace(EDGE_SPACE, "");
}

/** True when a message text is allowed: not empty and at most 2,000 characters. */
export function isValidMessageText(text: string): boolean {
  if (text.length === 0) return false;
  // Quick exit: fewer UTF-16 units than the limit means fewer characters too.
  if (text.length <= Limits.maxMessageLength) return true;
  return graphemeCount(text) <= Limits.maxMessageLength;
}
