/**
 * Cross-implementation checks against the real Swift code.
 *
 * Swift -> web: fixtures/swift-vectors.json was produced by EarshotKit's WebVectorsTests
 * (`EARSHOT_WRITE_VECTORS=1 swift test --filter WebVectors`). Every byte here must match it.
 *
 * Web -> Swift: this file also produces fixtures/ts-vectors.json from the same fixed keys.
 * EarshotKit's `acceptsWebClientOutput` test decodes it with the real Swift JSONDecoder,
 * channel and parsers. The file is deterministic; this test fails if the TypeScript output
 * changes without the fixture being regenerated (`EARSHOT_WRITE_VECTORS=1 npm test`).
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { concatBytes, fromHex, toHex, utf8 } from "../../src/engine/bytes";
import {
  Handshake,
  contactIDFor,
  discoveryTag,
  handshakeTranscript,
  identityFromSeed,
  knock,
  pairTag,
  safetyCode,
  sign,
  verifySignature,
} from "../../src/engine/crypto";
import {
  FrameKind,
  Reassembler,
  chunk,
  decodeFrame,
  decodeInviteContext,
  decodePayload,
  encodeBeacon,
  encodeBtFrame,
  encodeHello,
  encodeInviteBody,
  encodeInviteContext,
  encodePayload,
  encodeSealed,
  parseBeacon,
  type Payload,
} from "../../src/engine/wire";

const swiftURL = new URL("./fixtures/swift-vectors.json", import.meta.url);
const tsURL = new URL("./fixtures/ts-vectors.json", import.meta.url);

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Json = any;
const swift: Json = JSON.parse(readFileSync(swiftURL, "utf8"));
const h = (s: string) => fromHex(s);
const inputs = {
  phoneSeed: h(swift.inputs.phoneSeed),
  webSeed: h(swift.inputs.webSeed),
  phoneEphemeralSeed: h(swift.inputs.phoneEphemeralSeed),
  webEphemeralSeed: h(swift.inputs.webEphemeralSeed),
  phoneNonce: h(swift.inputs.phoneNonce),
  webNonce: h(swift.inputs.webNonce),
};
const phone = identityFromSeed(inputs.phoneSeed);
const web = identityFromSeed(inputs.webSeed);
const phoneHandshake = new Handshake(inputs.phoneEphemeralSeed);
const webHandshake = new Handshake(inputs.webEphemeralSeed);

describe("Swift -> web vectors", () => {
  it("derives the same identity keys and contact IDs as CryptoKit", () => {
    expect(toHex(phone.publicKey)).toBe(swift.identities.phonePublicKey);
    expect(toHex(web.publicKey)).toBe(swift.identities.webPublicKey);
    expect(contactIDFor(phone.publicKey)).toBe(swift.identities.phoneContactID);
    expect(contactIDFor(web.publicKey)).toBe(swift.identities.webContactID);
    expect(toHex(phoneHandshake.publicKey)).toBe(swift.identities.phoneEphemeralPublic);
    expect(toHex(webHandshake.publicKey)).toBe(swift.identities.webEphemeralPublic);
  });

  it("computes the same safety code, in either order", () => {
    expect(safetyCode(phone.publicKey, web.publicKey)).toBe(swift.safetyCode);
    expect(safetyCode(web.publicKey, phone.publicKey)).toBe(swift.safetyCodeSwapped);
    expect(swift.safetyCode).toBe(swift.safetyCodeSwapped);
    expect(swift.safetyCode).toMatch(/^\d{3} \d{3} \d{3}$/);
  });

  it("computes the same discovery tag, pair tag and knock", () => {
    const d = swift.discoveryTag;
    expect(toHex(discoveryTag(h(d.identityKey), h(d.nonce)))).toBe(d.tag);
    const p = swift.pairTag;
    expect(toHex(pairTag(h(p.a), h(p.b), h(p.inviterNonce), h(p.inviteeNonce)))).toBe(p.tag);
    // The pair tag does not depend on which key is passed first.
    expect(toHex(pairTag(h(p.b), h(p.a), h(p.inviterNonce), h(p.inviteeNonce)))).toBe(p.tag);
    const k = swift.knock;
    expect(toHex(knock(h(k.own), h(k.peer), h(k.signerEphemeral), h(k.peerEphemeral)))).toBe(k.knock);
  });

  it("builds and parses beacons byte for byte", () => {
    for (const b of swift.beacons) {
      const beacon = { displayName: b.name, nonce: h(b.nonce), tag: h(b.tag) };
      expect(toHex(encodeBeacon(beacon))).toBe(b.bytes);
      const parsed = parseBeacon(h(b.bytes));
      expect(parsed?.displayName).toBe(b.name);
      expect(toHex(parsed!.nonce)).toBe(b.nonce);
      expect(toHex(parsed!.tag)).toBe(b.tag);
    }
  });

  it("frames invitations the same way, and writes an equivalent context", () => {
    for (const invite of swift.invites) {
      const contextBytes = utf8(invite.contextJSON);
      expect(toHex(encodeInviteBody(h(invite.nonce), contextBytes))).toBe(invite.body);
      expect(toHex(encodeBtFrame(FrameKind.invite, h(invite.body)))).toBe(invite.frame);
      const decoded = decodeInviteContext(contextBytes)!;
      expect(decoded.v).toBe(1);
      expect(toHex(decoded.nonce)).toBe(invite.nonce);
      expect(decoded.name ?? null).toBe(invite.name ?? null);
      expect(decoded.tag ? toHex(decoded.tag) : null).toBe(invite.tag ?? null);
      // Our JSON may order keys differently; its meaning must be identical.
      expect(JSON.parse(new TextDecoder().decode(encodeInviteContext(decoded)))).toEqual(JSON.parse(invite.contextJSON));
    }
    expect(toHex(encodeBtFrame(FrameKind.accept))).toBe(swift.simpleFrames.accept);
    expect(toHex(encodeBtFrame(FrameKind.decline))).toBe(swift.simpleFrames.decline);
    expect(toHex(encodeBtFrame(FrameKind.close))).toBe(swift.simpleFrames.close);
    expect(toHex(encodeBtFrame(FrameKind.data, encodeHello(1, webHandshake.publicKey)))).toBe(swift.simpleFrames.dataHello);
  });

  it("decodes every payload Swift's JSONEncoder writes, and re-encodes it equivalently", () => {
    const cases = new Set<string>();
    for (const sample of swift.payloads) {
      const payload = decodePayload(utf8(sample.json));
      expect(payload.kind).toBe(sample.case);
      cases.add(payload.kind);
      const ours = JSON.parse(new TextDecoder().decode(encodePayload(payload)));
      expect(ours).toEqual(JSON.parse(sample.json));
    }
    expect([...cases].sort()).toEqual(["ack", "auth", "bye", "knock", "text"]);
    const text = decodePayload(utf8(swift.payloads.find((p: Json) => p.case === "text").json));
    expect(text).toEqual({ kind: "text", id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", text: 'Line one\nline "two" / slash 👋🏽 \u001fend' });
  });

  it("ignores unknown fields in auth (future capability flags), but refuses unknown payload cases", () => {
    const auth = JSON.parse(swift.payloads.find((p: Json) => p.case === "auth").json);
    auth.auth._0.features = ["photo-v1"]; // what photo-capable iPhones add (optional key)
    expect(decodePayload(utf8(JSON.stringify(auth))).kind).toBe("auth");
    expect(() => decodePayload(utf8('{"photo":{"_0":{}}}'))).toThrow();
  });

  it("cuts chunks at the same places", () => {
    for (const sample of swift.chunks) {
      const frame = h(sample.frame);
      const ours = chunk(frame, sample.maxChunkLength).map(toHex);
      expect(ours).toEqual(sample.chunks);
      const reassembler = new Reassembler();
      let result: Uint8Array | null = null;
      for (const piece of sample.chunks) result = reassembler.append(h(piece));
      expect(toHex(result!)).toBe(sample.frame);
    }
  });

  it("reproduces a whole encrypted conversation byte for byte", () => {
    const t = swift.transcript;
    const phoneHello = decodeFrame(h(t.phoneHello));
    expect(phoneHello.kind).toBe("hello");
    if (phoneHello.kind !== "hello") return;
    expect(toHex(encodeHello(1, webHandshake.publicKey))).toBe(t.webHello);
    const channel = webHandshake.channel(phoneHello.ephemeralKey);
    const phoneEph = phoneHello.ephemeralKey;
    const webEph = webHandshake.publicKey;
    for (const record of t.records) {
      if (record.from === "web") {
        const frame = encodeSealed(channel.seal(h(record.plaintext)));
        expect(toHex(frame)).toBe(record.frame);
        expect(toHex(encodeBtFrame(FrameKind.data, frame))).toBe(record.bluetooth);
        continue;
      }
      const decoded = decodeFrame(h(record.frame));
      if (decoded.kind !== "sealed") throw new Error("expected sealed");
      const plaintext = channel.open(decoded.box);
      expect(toHex(plaintext)).toBe(record.plaintext);
      const payload = decodePayload(plaintext);
      if (payload.kind === "auth") {
        expect(toHex(payload.identityKey)).toBe(toHex(phone.publicKey));
        // CryptoKit signatures are randomised, so we verify instead of comparing bytes.
        expect(verifySignature(payload.signature, handshakeTranscript(phoneEph, webEph), payload.identityKey)).toBe(true);
      }
      if (payload.kind === "knock") {
        expect(toHex(payload.knock)).toBe(toHex(knock(phone.publicKey, web.publicKey, phoneEph, webEph)));
      }
    }
  });

  it("refuses replayed, skipped and modified frames", () => {
    const t = swift.transcript;
    const phoneRecords = t.records.filter((r: Json) => r.from === "phone");
    const box = (r: Json) => h(r.frame).subarray(1);
    const fresh = () => webHandshake.channel(phoneHandshake.publicKey);

    const replay = fresh();
    replay.open(box(phoneRecords[0]));
    expect(() => replay.open(box(phoneRecords[0]))).toThrow();

    expect(() => fresh().open(box(phoneRecords[1]))).toThrow(); // skipped counter 0

    const tampered = box(phoneRecords[0]).slice();
    tampered[tampered.length - 1]! ^= 1;
    expect(() => fresh().open(tampered)).toThrow();

    expect(() => fresh().open(new Uint8Array(10))).toThrow();
    expect(() => webHandshake.channel(webHandshake.publicKey)).toThrow(); // our own key reflected back
    expect(() => webHandshake.channel(new Uint8Array(31))).toThrow();
  });
});

/** The browser's side, for EarshotKit's `acceptsWebClientOutput` test. */
function webVectors(): Json {
  const webEph = webHandshake.publicKey;
  const phoneEph = phoneHandshake.publicKey;
  const tag = pairTag(web.publicKey, phone.publicKey, inputs.webNonce, inputs.phoneNonce);
  const payloadSamples: Array<[Payload, Json]> = [
    [{ kind: "knock", knock: Uint8Array.from({ length: 32 }, (_, i) => i) }, {}],
    [
      { kind: "auth", identityKey: web.publicKey, name: 'Alex "A" / ü 🌙', signature: Uint8Array.from({ length: 64 }, (_, i) => 255 - i) },
      {},
    ],
    [{ kind: "text", id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", text: 'Line one\nline "two" / slash 👋🏽 \u001fend\u2028' }, {}],
    [{ kind: "ack", id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F" }, {}],
    [{ kind: "bye" }, {}],
  ];
  const payloads = payloadSamples.map(([p]) => {
    const json = new TextDecoder().decode(encodePayload(p));
    switch (p.kind) {
      case "knock":
        return { case: "knock", json, knock: toHex(p.knock) };
      case "auth":
        return { case: "auth", json, identityKey: toHex(p.identityKey), name: p.name, signature: toHex(p.signature) };
      case "text":
        return { case: "text", json, id: p.id, text: p.text };
      case "ack":
        return { case: "ack", json, id: p.id };
      case "bye":
        return { case: "bye", json };
    }
  });
  const invites = [
    { name: "Alex", tag: null },
    { name: null, tag },
  ].map((c) => {
    const context = encodeInviteContext({
      v: 1,
      nonce: inputs.webNonce,
      ...(c.name ? { name: c.name } : {}),
      ...(c.tag ? { tag: c.tag } : {}),
    });
    return {
      name: c.name,
      tag: c.tag ? toHex(c.tag) : null,
      frame: toHex(encodeBtFrame(FrameKind.invite, encodeInviteBody(inputs.webNonce, context))),
    };
  });
  const chunkSource = Uint8Array.from({ length: 400 }, (_, i) => (i * 7) & 255);
  const channel = webHandshake.channel(phoneEph);
  const script: Payload[] = [
    { kind: "knock", knock: knock(web.publicKey, phone.publicKey, webEph, phoneEph) },
    { kind: "auth", identityKey: web.publicKey, name: "Alex", signature: sign(web, handshakeTranscript(webEph, phoneEph)) },
    { kind: "text", id: "9B2E1A3C-0D4F-4E5A-8B6C-7D8E9F0A1B2C", text: "hello from the browser 🌙" },
    { kind: "ack", id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F" },
    { kind: "bye" },
  ];
  const records = script.map((p) => {
    const plaintext = encodePayload(p);
    return { plaintext: toHex(plaintext), frame: toHex(encodeSealed(channel.seal(plaintext))) };
  });
  return {
    about: "Generated by web/tests/unit/vectors.test.ts. Checked by EarshotKit WebVectorsTests.acceptsWebClientOutput.",
    inputs: swift.inputs,
    identities: { webPublicKey: toHex(web.publicKey), webContactID: contactIDFor(web.publicKey), webEphemeralPublic: toHex(webEph) },
    safetyCode: safetyCode(web.publicKey, phone.publicKey),
    discoveryTag: { identityKey: toHex(web.publicKey), nonce: toHex(inputs.webNonce), tag: toHex(discoveryTag(web.publicKey, inputs.webNonce)) },
    pairTag: { tag: toHex(tag) },
    knock: { knock: toHex(knock(web.publicKey, phone.publicKey, webEph, phoneEph)) },
    payloads,
    invites,
    beacon: {
      name: "Zoë 🌙",
      nonce: toHex(inputs.webNonce),
      bytes: toHex(encodeBeacon({ displayName: "Zoë 🌙", nonce: inputs.webNonce, tag: discoveryTag(web.publicKey, inputs.webNonce) })),
    },
    chunks: [180, 20].map((n) => ({ frame: toHex(chunkSource), maxChunkLength: n, chunks: chunk(chunkSource, n).map(toHex) })),
    transcript: { webHello: toHex(encodeHello(1, webEph)), records },
  };
}

describe("web -> Swift vectors", () => {
  it("matches the committed ts-vectors.json (regenerate with EARSHOT_WRITE_VECTORS=1)", () => {
    const ours = webVectors();
    const text = JSON.stringify(ours, null, 2) + "\n";
    if (process.env.EARSHOT_WRITE_VECTORS || !existsSync(tsURL)) {
      writeFileSync(tsURL, text);
    }
    expect(JSON.parse(readFileSync(tsURL, "utf8"))).toEqual(ours);
    // Sanity: our own decoder accepts our own output.
    for (const p of ours.payloads) expect(decodePayload(utf8(p.json)).kind).toBe(p.case);
    expect(concatBytes(new Uint8Array([1]), new Uint8Array([2]))).toEqual(new Uint8Array([1, 2]));
  });
});
