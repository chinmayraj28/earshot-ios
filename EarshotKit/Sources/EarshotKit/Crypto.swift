import CryptoKit
import Foundation

/// This phone's long-term identity: an Ed25519 signing key that never leaves the device.
public struct Identity: Sendable {
    private let key: Curve25519.Signing.PrivateKey

    public init() { key = Curve25519.Signing.PrivateKey() }

    public init(rawRepresentation: Data) throws {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public var contactID: ContactID { ContactID(identityKey: publicKey) }

    func sign(_ data: Data) throws -> Data { try key.signature(for: data) }

    static func verify(signature: Data, of data: Data, identityKey: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKey) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }
}

extension ContactID {
    public init(identityKey: Data) {
        let digest = SHA256.hash(data: identityKey)
        self.init(rawValue: digest.prefix(16).map { String(format: "%02x", $0) }.joined())
    }
}

/// A short number both people can compare in person. If it matches on both
/// phones, nobody is sitting in the middle of the connection.
public enum SafetyCode {
    public static func make(_ a: Data, _ b: Data) -> String {
        let (low, high) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        var hasher = SHA256()
        hasher.update(data: Data("earshot-safety-v1".utf8))
        hasher.update(data: low)
        hasher.update(data: high)
        let bytes = Array(hasher.finalize())
        return (0..<3).map { group -> String in
            let o = group * 4
            let value = (UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])) % 1000
            return String(format: "%03d", value)
        }.joined(separator: " ")
    }
}

/// Lets saved contacts recognise each other in the nearby list without
/// broadcasting anything a stranger could use to track a phone.
///
/// A phone announces a random `nonce` (new on every start) plus
/// `HMAC(identityKey, nonce)`. Only someone who already holds the identity key —
/// i.e. an existing contact — can recompute the tag and match it.
enum DiscoveryTag {
    static let nonceLength = 8
    static let tagLength = 8

    static func makeNonce() -> Data {
        Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func make(identityKey: Data, nonce: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: identityKey))
        return Data(Data(code).prefix(tagLength))
    }
}

/// A "knock" lets two saved contacts confirm they already know each other before
/// either one reveals who it is.
///
/// Without it, someone could re-broadcast a contact's beacon, let your phone
/// reconnect on its own, and collect your identity key from the proof step. The knock
/// is a MAC keyed with both identity keys, so only a phone that already holds both
/// can produce it — and to anyone else it is just random bytes.
enum Knock {
    static func make(ownIdentityKey: Data, peerIdentityKey: Data, signerEphemeral: Data, peerEphemeral: Data) -> Data {
        let (low, high) = ownIdentityKey.lexicographicallyPrecedes(peerIdentityKey)
            ? (ownIdentityKey, peerIdentityKey) : (peerIdentityKey, ownIdentityKey)
        let key = SymmetricKey(data: SHA256.hash(data: Data("earshot-knock-v1".utf8) + low + high))
        let transcript = Handshake.transcript(signerEphemeral: signerEphemeral, peerEphemeral: peerEphemeral)
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }
}

enum CryptoError: Error {
    case malformed
    case reflectedKey
    case replayed
}

/// One side of the key exchange that starts every link.
struct Handshake {
    static let version: UInt8 = 1

    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Data { ephemeral.publicKey.rawRepresentation }

    /// Derives the encrypted channel once the other side's ephemeral key is known.
    func channel(remoteEphemeral: Data) throws -> SecureChannel {
        let local = publicKey
        guard remoteEphemeral.count == 32 else { throw CryptoError.malformed }
        guard remoteEphemeral != local else { throw CryptoError.reflectedKey }
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: remoteKey)
        let localIsLow = local.lexicographicallyPrecedes(remoteEphemeral)
        let salt = localIsLow ? local + remoteEphemeral : remoteEphemeral + local
        func key(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                           sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        let lowToHigh = key("earshot v1 low>high")
        let highToLow = key("earshot v1 high>low")
        return SecureChannel(sendKey: localIsLow ? lowToHigh : highToLow,
                             receiveKey: localIsLow ? highToLow : lowToHigh)
    }

    /// What each side signs with its identity key. Covering both ephemeral keys
    /// ties the signature to this one link, so it cannot be replayed elsewhere.
    static func transcript(signerEphemeral: Data, peerEphemeral: Data) -> Data {
        Data("earshot-auth-v1".utf8) + signerEphemeral + peerEphemeral
    }
}

/// Authenticated encryption for one link, with separate keys per direction
/// and a counter that rejects replayed or re-ordered frames.
struct SecureChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var nextReceiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter))
        sendCounter += 1
        var out = Data()
        withUnsafeBytes(of: counter.bigEndian) { out.append(contentsOf: $0) }
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    mutating func open(_ frame: Data) throws -> Data {
        let frame = Data(frame)
        guard frame.count >= 8 + 16 else { throw CryptoError.malformed }
        let counter = frame.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter >= nextReceiveCounter else { throw CryptoError.replayed }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter),
                                           ciphertext: frame.dropFirst(8).dropLast(16),
                                           tag: frame.suffix(16))
        let plaintext = try ChaChaPoly.open(box, using: receiveKey)
        nextReceiveCounter = counter + 1
        return plaintext
    }
}
