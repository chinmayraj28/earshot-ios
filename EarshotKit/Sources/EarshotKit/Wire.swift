import Foundation

/// The outermost layer of everything sent between two phones.
enum Frame: Equatable {
    /// First frame in each direction, in the clear: protocol version + ephemeral key.
    case hello(version: UInt8, ephemeralKey: Data)
    /// Everything after that: an encrypted `Payload`.
    case sealed(Data)

    /// Generous cap; a 2,000 character message is at most ~8 KB of UTF-8.
    static let maxSize = 64 * 1024

    enum DecodingError: Error { case malformed }

    func encoded() -> Data {
        switch self {
        case .hello(let version, let key): return Data([1, version]) + key
        case .sealed(let box): return Data([2]) + box
        }
    }

    init(decoding raw: Data) throws {
        let data = Data(raw)
        guard let kind = data.first, data.count <= Frame.maxSize else { throw DecodingError.malformed }
        switch kind {
        case 1:
            guard data.count == 2 + 32 else { throw DecodingError.malformed }
            self = .hello(version: data[1], ephemeralKey: Data(data.dropFirst(2)))
        case 2:
            self = .sealed(Data(data.dropFirst(1)))
        default:
            throw DecodingError.malformed
        }
    }
}

/// What travels inside the encrypted channel.
enum Payload: Codable, Equatable {
    struct Auth: Codable, Equatable {
        var identityKey: Data
        var name: String
        var signature: Data
        /// What this phone's Earshot can do beyond plain text, for example `["photo-v1"]`.
        /// Optional so that older versions, which do not know the key, simply ignore it,
        /// and so that an `auth` from an older version (no key at all) decodes as "nothing extra".
        /// See `Feature`.
        var features: [String]? = nil
    }

    struct Text: Codable, Equatable {
        var id: UUID
        var text: String
    }

    /// Sent instead of `auth` when reconnecting to a saved contact: shows that the
    /// sender already knows both identity keys, without revealing either.
    case knock(Data)
    /// Proves who is on the other end.
    case auth(Auth)
    case text(Text)
    /// Receipt: the message with this id was received and stored.
    case ack(UUID)
    /// The other person closed the app or switched Earshot off.
    case bye

    // Photos (see `PhotoWire.swift`). Never sent to a phone whose `auth` did not list
    // `Feature.photo`: an older Earshot cannot decode these and would close the link.
    /// Sender → receiver: a photo is coming. Describes the whole file.
    case photoStart(PhotoStart)
    /// Sender → receiver: the next piece of the file, in order.
    case photoPiece(PhotoPiece)
    /// Receiver → sender: how many pieces have been stored so far. Paces the sender.
    case photoProgress(PhotoProgress)
    /// Sender → receiver: stop; throw away what you have of this photo.
    case photoCancel(UUID)
    /// Receiver → sender: I will not take this photo (too big, storage full, failed checks).
    case photoRefuse(UUID)

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Payload { try JSONDecoder().decode(Payload.self, from: data) }
}

/// Sent along with a connection request, before any link exists.
///
/// There are two kinds:
/// - a **request** from someone new carries their chosen `name` and always shows a prompt;
/// - a **reconnection** from a saved contact carries a `tag` (see `PairTag`) and no name.
///   It is accepted silently when the tag checks out and dropped silently when it does not.
struct InviteContext: Codable, Equatable {
    var v: Int = 1
    var name: String? = nil
    /// The inviter's session number, used to settle simultaneous invitations.
    var nonce: Data
    var tag: Data? = nil

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> InviteContext? {
        guard data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(InviteContext.self, from: data)
    }
}
