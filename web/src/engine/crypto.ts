/**
 * Earshot's cryptography, byte for byte the same as EarshotKit/Sources/EarshotKit/Crypto.swift.
 *
 * - Identity: an Ed25519 key that never leaves this browser. Its 32-byte "seed" is what
 *   CryptoKit calls `rawRepresentation`, so the same seed gives the same public key on both.
 * - Handshake: each side makes a one-time X25519 key; both derive two ChaCha20-Poly1305 keys
 *   (one per direction) with HKDF-SHA256.
 * - SecureChannel: every sealed frame starts with an 8-byte big-endian counter that must be
 *   exactly the next one expected, so replayed or re-ordered frames are refused.
 * - SafetyCode, DiscoveryTag, PairTag, Knock: small MACs and hashes described next to each function.
 */
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { ed25519, x25519 } from "@noble/curves/ed25519.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesEqual, compareBytes, concatBytes, randomBytes, readU64BE, toHex, u64BE, utf8 } from "./bytes";

export class CryptoError extends Error {}

// MARK: Identity

export interface Identity {
  /** 32-byte Ed25519 seed. Secret: stays in this browser's storage. */
  readonly seed: Uint8Array;
  readonly publicKey: Uint8Array;
}

export function newIdentity(): Identity {
  return identityFromSeed(randomBytes(32));
}

export function identityFromSeed(seed: Uint8Array): Identity {
  if (seed.length !== 32) throw new CryptoError("identity seed must be 32 bytes");
  return { seed: seed.slice(), publicKey: ed25519.getPublicKey(seed) };
}

export function sign(identity: Identity, message: Uint8Array): Uint8Array {
  return ed25519.sign(message, identity.seed);
}

export function verifySignature(signature: Uint8Array, message: Uint8Array, identityKey: Uint8Array): boolean {
  if (signature.length !== 64 || identityKey.length !== 32) return false;
  try {
    return ed25519.verify(signature, message, identityKey);
  } catch {
    return false;
  }
}

/** First 16 bytes of SHA-256(identity key), as lowercase hex. Example: "65b60673d6ed884bf01c2c222d82ada0". */
export function contactIDFor(identityKey: Uint8Array): string {
  return toHex(sha256(identityKey).subarray(0, 16));
}

// MARK: Codes and tags

/** Orders two keys the way Swift does ("low" first). */
function lowHigh(a: Uint8Array, b: Uint8Array): [Uint8Array, Uint8Array] {
  return compareBytes(a, b) < 0 ? [a, b] : [b, a];
}

/**
 * The nine digits two people compare in person, e.g. "065 828 378".
 * SHA-256("earshot-safety-v1" + low key + high key); three groups of 4 bytes, each mod 1000.
 */
export function safetyCode(a: Uint8Array, b: Uint8Array): string {
  const [low, high] = lowHigh(a, b);
  const digest = sha256(concatBytes(utf8("earshot-safety-v1"), low, high));
  const view = new DataView(digest.buffer, digest.byteOffset, digest.byteLength);
  return [0, 1, 2].map((g) => String(view.getUint32(g * 4, false) % 1000).padStart(3, "0")).join(" ");
}

export const DISCOVERY_NONCE_LENGTH = 8;
export const DISCOVERY_TAG_LENGTH = 8;

/** HMAC-SHA256(key = identity key, data = nonce), first 8 bytes. Lets contacts recognise a phone's beacon. */
export function discoveryTag(identityKey: Uint8Array, nonce: Uint8Array): Uint8Array {
  return hmac(sha256, identityKey, nonce).subarray(0, DISCOVERY_TAG_LENGTH);
}

/** SHA-256(purpose + low key + high key): a secret only these two contacts can compute. */
function pairSecret(a: Uint8Array, b: Uint8Array, purpose: string): Uint8Array {
  const [low, high] = lowHigh(a, b);
  return sha256(concatBytes(utf8(purpose), low, high));
}

export const PAIR_TAG_LENGTH = 16;

/** Marks a reconnection invitation as coming from a saved contact. */
export function pairTag(a: Uint8Array, b: Uint8Array, inviterNonce: Uint8Array, inviteeNonce: Uint8Array): Uint8Array {
  const key = pairSecret(a, b, "earshot-pair-v1");
  return hmac(sha256, key, concatBytes(inviterNonce, inviteeNonce)).subarray(0, PAIR_TAG_LENGTH);
}

/** "earshot-auth-v1" + signer's one-time key + peer's one-time key. What the identity proof signs. */
export function handshakeTranscript(signerEphemeral: Uint8Array, peerEphemeral: Uint8Array): Uint8Array {
  return concatBytes(utf8("earshot-auth-v1"), signerEphemeral, peerEphemeral);
}

/** Proves "I already know both our identity keys" without revealing either. 32 bytes. */
export function knock(
  ownIdentityKey: Uint8Array,
  peerIdentityKey: Uint8Array,
  signerEphemeral: Uint8Array,
  peerEphemeral: Uint8Array,
): Uint8Array {
  const key = pairSecret(ownIdentityKey, peerIdentityKey, "earshot-knock-v1");
  return hmac(sha256, key, handshakeTranscript(signerEphemeral, peerEphemeral));
}

// MARK: Handshake and channel

export const HANDSHAKE_VERSION = 1;

/** One side of the key exchange that starts every link. */
export class Handshake {
  readonly publicKey: Uint8Array;
  readonly #secret: Uint8Array;

  /** `fixedSecret` is only for tests that need the same bytes every run. */
  constructor(fixedSecret?: Uint8Array) {
    this.#secret = fixedSecret ? fixedSecret.slice() : x25519.utils.randomSecretKey();
    this.publicKey = x25519.getPublicKey(this.#secret);
  }

  /** Derives the encrypted channel once the other side's one-time key is known. Throws on bad keys. */
  channel(remoteEphemeral: Uint8Array): SecureChannel {
    const local = this.publicKey;
    if (remoteEphemeral.length !== 32) throw new CryptoError("malformed key");
    // Someone sending our own key back to us is an attack, not a peer.
    if (bytesEqual(remoteEphemeral, local)) throw new CryptoError("reflected key");
    let shared: Uint8Array;
    try {
      shared = x25519.getSharedSecret(this.#secret, remoteEphemeral);
    } catch {
      throw new CryptoError("bad key");
    }
    const localIsLow = compareBytes(local, remoteEphemeral) < 0;
    const salt = localIsLow ? concatBytes(local, remoteEphemeral) : concatBytes(remoteEphemeral, local);
    const key = (label: string) => hkdf(sha256, shared, salt, utf8(label), 32);
    const lowToHigh = key("earshot v1 low>high");
    const highToLow = key("earshot v1 high>low");
    return new SecureChannel(localIsLow ? lowToHigh : highToLow, localIsLow ? highToLow : lowToHigh);
  }
}

const MAX_COUNTER = 0xffff_ffff_ffff_ffffn;

/**
 * Authenticated encryption for one link. A sealed frame is
 * `[8-byte big-endian counter][ciphertext][16-byte tag]`; the nonce is 4 zero bytes + the counter.
 */
export class SecureChannel {
  #sendKey: Uint8Array;
  #receiveKey: Uint8Array;
  #sendCounter = 0n;
  #nextReceiveCounter = 0n;

  constructor(sendKey: Uint8Array, receiveKey: Uint8Array) {
    this.#sendKey = sendKey;
    this.#receiveKey = receiveKey;
  }

  static #nonce(counter: bigint): Uint8Array {
    return concatBytes(new Uint8Array(4), u64BE(counter));
  }

  seal(plaintext: Uint8Array): Uint8Array {
    const counter = this.#sendCounter;
    if (counter >= MAX_COUNTER) throw new CryptoError("counter exhausted");
    const box = chacha20poly1305(this.#sendKey, SecureChannel.#nonce(counter)).encrypt(plaintext);
    this.#sendCounter = counter + 1n;
    return concatBytes(u64BE(counter), box);
  }

  /** Throws on anything but the next frame in order, unmodified. */
  open(frame: Uint8Array): Uint8Array {
    if (frame.length < 8 + 16) throw new CryptoError("malformed");
    const counter = readU64BE(frame, 0);
    // The link delivers frames in order, so the only valid counter is the next one. `.max` is never valid.
    if (counter !== this.#nextReceiveCounter || counter >= MAX_COUNTER) throw new CryptoError("replayed");
    let plaintext: Uint8Array;
    try {
      plaintext = chacha20poly1305(this.#receiveKey, SecureChannel.#nonce(counter)).decrypt(frame.subarray(8));
    } catch {
      throw new CryptoError("forged");
    }
    this.#nextReceiveCounter = counter + 1n;
    return plaintext;
  }
}
