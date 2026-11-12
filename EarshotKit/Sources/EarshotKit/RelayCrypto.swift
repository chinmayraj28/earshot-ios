import CryptoKit
import Foundation

/// The keys behind relayed messages ("relay-v1"): messages that travel to a contact through
/// friends' phones while the two of you are out of range. See `docs/HOW_IT_WORKS.md`.
///
/// Nothing here is derived from `PairSecret`. That one is computed from two *public* keys, so
/// a friend you both share could compute it too, and friends are exactly who carries the mail.
/// Everything here starts from the private X25519 secret of a direct link instead.
///
/// The key schedule, in order:
///
/// 1. **Root.** Every direct link between two contacts that both announce `relay-v1` derives
///    `root = HKDF-SHA256(ikm: S, salt: lowEphemeral ‖ highEphemeral,
///                        info: "earshot relay root v1" ‖ lowIdentityKey ‖ highIdentityKey)`,
///    where S is the link's X25519 shared secret (already authenticated by both identity proofs).
/// 2. **Generation ID.** `HKDF-Expand(root, "earshot relay gen v1", 8)`. Both phones compute the
///    same 8 bytes; exchanging them (`relaySync`) proves the other phone derived the same root.
/// 3. **Chains.** One per direction:
///    `CK0[A→B] = HKDF-Expand(root, "earshot relay chain v1" ‖ IK_A ‖ IK_B, 32)`. The root is then forgotten.
/// 4. **Per message** `i`: `MK_i = HMAC(CK_i, 0x01)` (the ChaCha20-Poly1305 key),
///    `tag_i = HMAC(CK_i, 0x02)[0..<16]`, `RS_i = HMAC(CK_i, 0x03)[0..<16]` (the receipt secret),
///    `CK_{i+1} = HMAC(CK_i, 0x04)`. Old chain keys are deleted, so a later theft of the phone
///    cannot reopen a message that was already delivered.
enum RelayCrypto {
    static let rootLabel = "earshot relay root v1"
    static let generationLabel = "earshot relay gen v1"
    static let chainLabel = "earshot relay chain v1"

    /// Derives the root of a new generation from a direct link.
    /// Returns nil when the shared secret is all zeros (a low-order key: never relay on that).
    static func root(sharedSecret: SymmetricKey, localEphemeral: Data, remoteEphemeral: Data,
                     ownIdentityKey: Data, peerIdentityKey: Data) -> SymmetricKey? {
        let allZero = sharedSecret.withUnsafeBytes { $0.allSatisfy { $0 == 0 } }
        guard !allZero else { return nil }
        let salt = localEphemeral.lexicographicallyPrecedes(remoteEphemeral)
            ? localEphemeral + remoteEphemeral : remoteEphemeral + localEphemeral
        let (low, high) = ownIdentityKey.lexicographicallyPrecedes(peerIdentityKey)
            ? (ownIdentityKey, peerIdentityKey) : (peerIdentityKey, ownIdentityKey)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedSecret, salt: salt,
                                      info: Data(rootLabel.utf8) + low + high, outputByteCount: 32)
    }

    static func generationID(root: SymmetricKey) -> Data {
        expand(root, info: Data(generationLabel.utf8), count: 8)
    }

    /// The first chain key for messages from `sender` to `recipient` (identity public keys).
    static func chainStart(root: SymmetricKey, sender: Data, recipient: Data) -> Data {
        expand(root, info: Data(chainLabel.utf8) + sender + recipient, count: 32)
    }

    struct Step {
        let messageKey: SymmetricKey
        let tag: Data
        let receiptSecret: Data
        let next: Data
    }

    /// Everything derived from one chain key.
    static func step(_ chainKey: Data) -> Step {
        let key = SymmetricKey(data: chainKey)
        func mac(_ byte: UInt8) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data([byte]), using: key)) }
        return Step(messageKey: SymmetricKey(data: mac(0x01)), tag: Data(mac(0x02).prefix(16)),
                    receiptSecret: Data(mac(0x03).prefix(16)), next: mac(0x04))
    }

    /// Just the next chain key and this index's tag (cheaper bookkeeping for the lookahead table).
    static func tagAndNext(_ chainKey: Data) -> (tag: Data, next: Data) {
        let key = SymmetricKey(data: chainKey)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key)).prefix(16)
        let next = Data(HMAC<SHA256>.authenticationCode(for: Data([0x04]), using: key))
        return (Data(tag), next)
    }

    /// What carriers compare a released receipt secret against: `SHA-256(RS)[0..<16]`.
    static func receiptHash(_ receiptSecret: Data) -> Data { Data(SHA256.hash(data: receiptSecret).prefix(16)) }

    /// Names an envelope for offers and duplicate checks: `SHA-256(whole envelope)[0..<8]`.
    /// Computed over every byte, so junk that copies a real tag gets a different name.
    static func envelopeID(_ envelope: Data) -> Data { Data(SHA256.hash(data: envelope).prefix(8)) }

    private static func expand(_ prk: SymmetricKey, info: Data, count: Int) -> Data {
        HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }
}

/// The text inside an envelope, before padding.
struct RelayInner: Equatable {
    static let textType: UInt8 = 1
    /// type (1) + message ID (16) + sentAt (8) + length (2).
    static let headerLength = 27

    var messageID: UUID
    /// Milliseconds since 1970, from the sender's clock.
    var sentAt: UInt64
    var text: String

    enum DecodingError: Error { case malformed }

    /// The padded plaintext for a bucket of `size` bytes in total, or nil if the text does not fit.
    func encoded(bucket size: Int) -> Data? {
        let utf8 = Data(text.utf8)
        let capacity = size - RelayEnvelope.overhead - Self.headerLength
        guard utf8.count <= capacity, utf8.count <= Int(UInt16.max) else { return nil }
        var out = Data([Self.textType])
        withUnsafeBytes(of: messageID.uuid) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: sentAt.bigEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(utf8.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(utf8)
        out.append(Data(count: size - RelayEnvelope.overhead - out.count))
        return out
    }

    /// Reads a padded plaintext. Rejects unknown types, lengths past the end, non-zero padding
    /// and invalid UTF-8.
    static func decode(_ plain: Data) throws -> RelayInner {
        let bytes = [UInt8](plain)
        guard bytes.count >= headerLength, bytes[0] == textType else { throw DecodingError.malformed }
        let uuid = UUID(uuid: (bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                               bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15], bytes[16]))
        let sentAt = bytes[17..<25].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let length = Int(bytes[25]) << 8 | Int(bytes[26])
        guard headerLength + length <= bytes.count,
              bytes[(headerLength + length)...].allSatisfy({ $0 == 0 }),
              let text = String(bytes: bytes[headerLength..<(headerLength + length)], encoding: .utf8)
        else { throw DecodingError.malformed }
        return RelayInner(messageID: uuid, sentAt: sentAt, text: text)
    }
}

/// A sealed relayed message. Always exactly 512, 2,048 or 8,192 bytes.
///
/// | Offset | Bytes | Field |
/// |---|---|---|
/// | 0 | 1 | version = 1 |
/// | 1 | 16 | tag (one-time, only the recipient recognises it) |
/// | 17 | 16 | receiptHash = SHA-256(receipt secret)[0..<16] |
/// | 33 | 4 | expiresHour: hours since 1970, big-endian, a multiple of 6, at most 48 h ahead |
/// | 37 | 12 | nonce (random) |
/// | 49 | n | ChaCha20-Poly1305 ciphertext of the padded `RelayInner`, AAD = bytes 0..<49 |
/// | end−16 | 16 | Poly1305 tag |
///
/// There is no sender, no recipient, no hop counter and no compression. A carrier reads only the
/// 49-byte header and never decrypts anything.
struct RelayEnvelope: Equatable {
    static let version: UInt8 = 1
    static let buckets = [512, 2048, 8192]
    static let headerLength = 49
    static let overhead = 65

    let bytes: Data

    var tag: Data { Data(bytes[bytes.startIndex + 1 ..< bytes.startIndex + 17]) }
    var receiptHash: Data { Data(bytes[bytes.startIndex + 17 ..< bytes.startIndex + 33]) }
    var expiresHour: UInt32 {
        bytes[bytes.startIndex + 33 ..< bytes.startIndex + 37].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    var header: Data { Data(bytes.prefix(Self.headerLength)) }
    var id: Data { RelayCrypto.envelopeID(bytes) }
    var expires: Date { Date(timeIntervalSince1970: TimeInterval(expiresHour) * 3600) }

    /// Accepts only a well-formed outer shape: a known size and version. Says nothing about
    /// whether the contents are genuine (only the recipient can tell).
    init?(parsing data: Data) {
        let data = Data(data)
        guard Self.buckets.contains(data.count), data.first == Self.version else { return nil }
        bytes = data
    }

    private init(raw: Data) { bytes = raw }

    /// `expiresHour` for an envelope made at `now`: 48 hours ahead, rounded down to 6 hours.
    static func expiresHour(at now: Date) -> UInt32 {
        let hours = Int(now.timeIntervalSince1970 / 3600) + RelayLimits.lifetimeHours
        return UInt32(clamping: hours - hours % RelayLimits.expiryStepHours)
    }

    /// True while a carrier should keep it: not expired, and not claiming an expiry further
    /// ahead than any honest phone would write (allowing an hour of clock difference).
    func isFresh(at now: Date) -> Bool {
        let expiry = TimeInterval(expiresHour) * 3600
        let t = now.timeIntervalSince1970
        return expiry > t && expiry <= t + TimeInterval(RelayLimits.lifetimeHours + 1) * 3600
    }

    static func seal(_ inner: RelayInner, step: RelayCrypto.Step, expiresHour: UInt32,
                     nonce: Data? = nil) throws -> RelayEnvelope? {
        let textBytes = inner.text.utf8.count
        guard let size = buckets.first(where: { textBytes <= $0 - overhead - RelayInner.headerLength }),
              let plain = inner.encoded(bucket: size) else { return nil }
        var header = Data([version])
        header.append(step.tag)
        header.append(RelayCrypto.receiptHash(step.receiptSecret))
        withUnsafeBytes(of: expiresHour.bigEndian) { header.append(contentsOf: $0) }
        let nonceBytes = nonce ?? Data(ChaChaPoly.Nonce())
        header.append(nonceBytes)
        let box = try ChaChaPoly.seal(plain, using: step.messageKey, nonce: try ChaChaPoly.Nonce(data: nonceBytes),
                                      authenticating: header)
        return RelayEnvelope(raw: header + box.ciphertext + box.tag)
    }

    /// Decrypts with the message key for this envelope's tag. Throws if anything was changed.
    func open(with key: SymmetricKey) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: bytes[bytes.startIndex + 37 ..< bytes.startIndex + 49])
        let body = bytes.dropFirst(Self.headerLength)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: body.dropLast(16), tag: body.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: header)
    }
}
