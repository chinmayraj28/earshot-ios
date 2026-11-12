/** Name and message rules shared with the phone (Models.swift `Limits`). */
import { describe, expect, it } from "vitest";
import { fromBase64, toBase64 } from "../../src/engine/bytes";
import { graphemeCount, isValidMessageText, sanitizedName, trimmed } from "../../src/engine/text";

describe("sanitizedName", () => {
  it("cleans names like the phone does", () => {
    expect(sanitizedName("  Maya\n  Okafor​ ")).toBe("Maya Okafor");
    expect(sanitizedName("a\u0000b\tc")).toBe("abc");
    expect(sanitizedName("Zoë 🌙")).toBe("Zoë 🌙");
    expect(sanitizedName("x".repeat(40))).toBe("x".repeat(32));
    // 32 characters but more than 96 bytes: trimmed by bytes.
    expect(new TextEncoder().encode(sanitizedName("😀".repeat(32))).length).toBeLessThanOrEqual(96);
    expect(sanitizedName("😀".repeat(32))).toBe("😀".repeat(24));
    expect(sanitizedName("\n\n")).toBe("");
  });
});

describe("messages", () => {
  it("counts characters as Swift does and trims edges", () => {
    expect(graphemeCount("👋🏽")).toBe(1);
    expect(graphemeCount("é")).toBe(1);
    expect(trimmed("  hi \n ")).toBe("hi");
    expect(isValidMessageText("")).toBe(false);
    expect(isValidMessageText("a".repeat(2000))).toBe(true);
    expect(isValidMessageText("a".repeat(2001))).toBe(false);
    expect(isValidMessageText("👋🏽".repeat(2000))).toBe(true);
    expect(isValidMessageText("👋🏽".repeat(2001))).toBe(false);
  });

  it("replaces lone surrogates, which Swift strings cannot hold", () => {
    expect(trimmed("a\uD800b")).toBe("a�b");
  });
});

describe("base64", () => {
  it("is strict like Swift's Data(base64Encoded:)", () => {
    for (const n of [0, 1, 2, 3, 31, 32, 64]) {
      const bytes = Uint8Array.from({ length: n }, (_, i) => (i * 37) & 255);
      expect(fromBase64(toBase64(bytes))).toEqual(bytes);
      expect(toBase64(bytes)).toBe(Buffer.from(bytes).toString("base64"));
    }
    expect(fromBase64("AAE")).toBeNull(); // missing padding
    expect(fromBase64("AA-_")).toBeNull(); // URL-safe letters
    expect(fromBase64("AA E")).toBeNull();
    expect(fromBase64("=AAA")).toBeNull();
  });
});
