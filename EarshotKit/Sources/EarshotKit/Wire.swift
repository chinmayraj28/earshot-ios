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

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> Payload { try JSONDecoder().decode(Payload.self, from: data) }
}

/// Sent along with a connection request, before any link exists.
struct InviteContext: Codable, Equatable {
    var v: Int = 1
    var name: String
    var nonce: Data
    var tag: Data

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> InviteContext? {
        guard data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(InviteContext.self, from: data)
    }
}
