import Foundation

/// Optional abilities a phone announces in its identity proof (`Payload.Auth.features`).
///
/// A phone only uses an ability with a peer that announced it **on the current link**.
/// Example: Alex's Earshot can send photos, Blake runs an older version. Blake's `auth`
/// has no `features` key, so Alex's phone never sends Blake a photo payload (which
/// Blake's phone could not decode, and would answer by closing the link).
enum Feature {
    /// Can receive and send photos with the `photo…` payloads below.
    static let photo = "photo-v1"

    /// Takes part in relaying: carries sealed messages for contacts and has its own carried.
    /// Announced only while the carry setting is not `.off` (see `CarryMode`, `Messenger+Relay.swift`).
    static let relay = "relay-v1"

    /// Everything this version of Earshot can announce. What a phone actually announces on a
    /// link is `Messenger.announcedFeatures` (relaying can be switched off).
    static let all = [photo, relay]
}

/// The numbers that keep photos honest about what Bluetooth LE can carry.
public enum PhotoLimits {
    /// Longest side of a prepared photo, in pixels. Enough to fill a phone screen
    /// (an iPhone is about 1,180–1,320 pixels wide), small enough to send in seconds.
    public static let maxLongSide = 1280
    /// What preparation aims for. At the expected 5–50 KB/s this is about 4–40 seconds
    /// including the encoding overhead below (not measured on phones yet).
    public static let targetBytes = 150_000
    /// Preparation gives up rather than produce a file bigger than this.
    public static let maxPreparedBytes = 400_000
    /// The largest photo a phone accepts. Above what this version ever sends, so a
    /// slightly more generous future version still works; far below what could hurt.
    public static let maxIncomingBytes = 1_048_576
    /// Bytes of photo per piece. Each piece travels as one sealed frame of about
    /// 5.5 KB (base64 inside JSON adds about a third), far below the 64 KB frame cap.
    /// Small pieces keep text responsive: a text message waits behind at most
    /// `piecesInFlight` pieces, never behind a whole photo.
    public static let pieceBytes = 4096
    /// The largest piece a phone accepts from others.
    public static let maxIncomingPieceBytes = 16_384
    /// Pieces the sender may have sent but not yet seen confirmed.
    public static let piecesInFlight = 3
    /// Photos one link may be receiving at the same time. More are refused.
    public static let maxConcurrentIncoming = 2
    /// Size of the tiny blurred preview sent ahead of a photo.
    public static let maxPreviewBytes = 2048
    public static let previewLongSide = 24
    /// A received image is decoded only if its real size (read from the file, never
    /// from what the sender claims) is at most this many pixels per side and in total.
    /// Stops a "decompression bomb": a small file that would unpack to gigabytes.
    public static let maxDecodedSide = 4096
    public static let maxDecodedPixels = 4096 * 4096
}

/// "A photo is coming." Sent once at the start of every attempt.
///
/// `size` and `sha256` describe the exact bytes that will follow (a JPEG). The receiver
/// checks both before it accepts the photo. `width`, `height` and `preview` are hints for
/// drawing a placeholder while the photo arrives; the receiver never trusts them for
/// anything else.
struct PhotoStart: Codable, Equatable {
    /// The message ID. A receipt (`Payload.ack`) with this ID means "fully received,
    /// checked and stored".
    var id: UUID
    var size: Int
    /// SHA-256 of the whole file, 32 bytes.
    var sha256: Data
    var width: Int
    var height: Int
    /// A very small JPEG (at most `PhotoLimits.maxPreviewBytes`) for a blurred placeholder.
    var preview: Data? = nil
    /// Optional text sent with the photo. Same length limit as a message.
    var caption: String? = nil
}

/// One piece of the file. `index` counts from 0 and must be exactly the next one.
struct PhotoPiece: Codable, Equatable {
    var id: UUID
    var index: Int
    var data: Data
}

/// "I have stored this many pieces of photo `id`." Sent after every piece.
struct PhotoProgress: Codable, Equatable {
    var id: UUID
    var received: Int
}
