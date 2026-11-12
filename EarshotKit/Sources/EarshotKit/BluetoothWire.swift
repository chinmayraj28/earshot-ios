import Foundation

/// The byte formats used on the Bluetooth link, kept free of any radio code so they
/// can be tested on their own.
///
/// Bluetooth LE moves data in small pieces (often under 200 bytes), so every frame is
/// cut into chunks. Each chunk starts with one byte: `0` means "more follows", `1`
/// means "this is the last piece".
enum BluetoothWire {
    /// Largest frame a peer may send. A full-length message is far below this.
    static let maxFrameLength = 64 * 1024
    /// Largest frame accepted from a phone that has no link with us yet (an invitation).
    static let maxUnlinkedFrameLength = 4 * 1024
    static let beaconVersion: UInt8 = 1

    enum Kind: UInt8 {
        /// "I would like to open a link." Only sent by the side that made the Bluetooth connection.
        case invite = 1
        case accept = 2
        case decline = 3
        /// Opaque bytes for the engine.
        case data = 4
        /// The sender has closed its end of the link.
        case close = 5
    }

    enum WireError: Error {
        case frameTooLong
        case malformedChunk
    }

    // MARK: Beacon

    /// What a phone lets nearby phones read before any link exists:
    /// `[version][nonce length][nonce][tag length][tag][name as UTF-8]`.
    static func beacon(_ advertisement: LocalAdvertisement) -> Data {
        var data = Data([beaconVersion])
        data.append(UInt8(clamping: advertisement.nonce.count))
        data.append(advertisement.nonce.prefix(255))
        data.append(UInt8(clamping: advertisement.tag.count))
        data.append(advertisement.tag.prefix(255))
        data.append(Data(advertisement.displayName.utf8).prefix(Limits.maxNameBytes))
        return data
    }

    static func parseBeacon(_ data: Data) -> LocalAdvertisement? {
        var bytes = [UInt8](data)[...]
        guard bytes.popFirst() == beaconVersion,
              let nonce = takePrefixed(&bytes), let tag = takePrefixed(&bytes),
              bytes.count <= Limits.maxNameBytes,
              let name = String(bytes: bytes, encoding: .utf8) else { return nil }
        return LocalAdvertisement(displayName: name, nonce: nonce, tag: tag, isVisible: true)
    }

    // MARK: Frames

    static func frame(_ kind: Kind, _ body: Data = Data()) -> Data {
        var data = Data([kind.rawValue])
        data.append(body)
        return data
    }

    static func parseFrame(_ data: Data) -> (kind: Kind, body: Data)? {
        guard let first = data.first, let kind = Kind(rawValue: first) else { return nil }
        return (kind, Data(data.dropFirst()))
    }

    /// An invitation carries the inviter's current nonce in front of the engine's own
    /// context, so the receiving phone can tell that this Bluetooth connection belongs to
    /// a phone it has already seen nearby.
    static func inviteBody(nonce: Data, context: Data) -> Data {
        var data = Data([UInt8(clamping: nonce.count)])
        data.append(nonce.prefix(255))
        data.append(context)
        return data
    }

    static func parseInviteBody(_ body: Data) -> (nonce: Data, context: Data)? {
        var bytes = [UInt8](body)[...]
        guard let nonce = takePrefixed(&bytes) else { return nil }
        return (nonce, Data(bytes))
    }

    private static func takePrefixed(_ bytes: inout ArraySlice<UInt8>) -> Data? {
        guard let length = bytes.popFirst(), bytes.count >= Int(length) else { return nil }
        let value = Data(bytes.prefix(Int(length)))
        bytes = bytes.dropFirst(Int(length))
        return value
    }

    // MARK: Long writes

    /// Largest value a single Bluetooth attribute write may carry (Bluetooth Core spec, ATT).
    static let maxAttributeValueLength = 512

    /// One write request as Core Bluetooth hands it over: who wrote, where in the value, and what.
    struct WritePiece: Equatable {
        let writer: UUID
        let offset: Int
        let value: Data
    }

    /// Joins the pieces of "long writes" back into whole values.
    ///
    /// Why this exists: a phone or a browser that wants to write more bytes than fit in one
    /// Bluetooth packet sends a "long write". iOS then hands us several requests in one batch:
    /// the first with offset 0, the next ones with offset 180, 360 ... continuing the same value.
    /// Chrome does this on its own when a web page writes a chunk that is larger than the
    /// connection allows. Each joined value is one chunk for `Reassembler`.
    ///
    /// Example: pieces (A, 0, 180 bytes), (A, 180, 20 bytes), (B, 0, 50 bytes) become
    /// [(A, 200 bytes), (B, 50 bytes)].
    ///
    /// Returns nil, so the whole batch is refused, when a piece with an offset does not continue
    /// the previous piece exactly (other writer, gap or overlap) or a joined value is too long.
    static func mergeWrites(_ pieces: [WritePiece]) -> [(writer: UUID, value: Data)]? {
        var merged: [(writer: UUID, value: Data)] = []
        for piece in pieces {
            if piece.offset == 0 {
                merged.append((piece.writer, piece.value))
            } else {
                guard let last = merged.last, last.writer == piece.writer, last.value.count == piece.offset else { return nil }
                merged[merged.count - 1].value.append(piece.value)
            }
            guard let current = merged.last, current.value.count <= maxAttributeValueLength else { return nil }
        }
        return merged
    }

    // MARK: Chunking

    /// Cuts a frame into pieces of at most `maxChunkLength` bytes, marker byte included.
    static func chunks(of frame: Data, maxChunkLength: Int) -> [Data] {
        let payload = max(maxChunkLength - 1, 1)
        let bytes = [UInt8](frame)
        var result: [Data] = []
        var index = 0
        repeat {
            let end = min(index + payload, bytes.count)
            var chunk = Data([end == bytes.count ? 1 : 0])
            chunk.append(contentsOf: bytes[index..<end])
            result.append(chunk)
            index = end
        } while index < bytes.count
        return result
    }

    /// Puts chunks back together. One per direction of a Bluetooth connection.
    struct Reassembler {
        private var buffer = Data()

        /// Returns a whole frame once its last chunk has arrived.
        mutating func append(_ chunk: Data, limit: Int = BluetoothWire.maxFrameLength) throws -> Data? {
            guard let marker = chunk.first, marker <= 1 else {
                buffer = Data()
                throw WireError.malformedChunk
            }
            buffer.append(chunk.dropFirst())
            guard buffer.count <= limit else {
                buffer = Data()
                throw WireError.frameTooLong
            }
            guard marker == 1 else { return nil }
            defer { buffer = Data() }
            return buffer
        }

        mutating func reset() { buffer = Data() }
    }
}
