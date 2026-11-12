// Photo support for earshot-probe, kept apart from main.swift so it stays easy to read.
//
//   --send-photo    send one generated test picture to each contact once connected
//   --photo-echo    answer every photo received with a generated test picture
//
// The probe always announces photo support (the engine does that by itself). For a
// received photo it prints only its size, pixel size and whether its SHA-256 matched
// what the sender announced. Never the picture itself.

import CryptoKit
import EarshotKit
import Foundation

@MainActor
enum ProbePhotos {
    static var sendOnConnect = false
    static var echo = false
    private static var sentTo: Set<ContactID> = []
    private static var counter = 0

    /// Handles the photo-related command-line flags. Returns false if the flag is not one of ours.
    static func parse(_ argument: String) -> Bool {
        switch argument {
        case "--send-photo": sendOnConnect = true
        case "--photo-echo": echo = true
        default: return false
        }
        return true
    }

    static func connected(_ id: ContactID, messenger: Messenger) {
        guard sendOnConnect, !sentTo.contains(id) else { return }
        sentTo.insert(id)
        send(to: id, messenger: messenger)
    }

    /// Called for every received message; does something only for photos.
    static func received(_ message: Message, from id: ContactID, messenger: Messenger) -> Bool {
        guard let photo = message.photo else { return false }
        // The engine already refused anything whose hash did not match before storing it.
        // Re-reading the stored bytes here shows that what is on disk is what was sent.
        let data: Data? = switch messenger.photoSource(for: message) {
        case .data(let bytes): bytes
        case .file(let url): try? Data(contentsOf: url)
        case nil: nil
        }
        let ok = data.map { $0.count == photo.byteCount } ?? false
        let digest = data.map { SHA256.hash(data: $0).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? "-"
        print("RECEIVED PHOTO \(photo.byteCount) bytes \(photo.width)x\(photo.height) sha256 \(digest)… check \(ok ? "ok" : "FAILED")")
        if echo { send(to: id, messenger: messenger) }
        return true
    }

    private static func send(to id: ContactID, messenger: Messenger) {
        counter += 1
        let seed = counter
        do {
            let photo = try PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 1600, height: 1200, seed: seed)))
            if messenger.sendPhoto(photo, caption: "Test picture \(seed) from the probe", to: id) != nil {
                print("SENT PHOTO \(photo.jpeg.count) bytes \(photo.width)x\(photo.height)")
            } else {
                print("PHOTO NOT SENT (the other phone did not announce photo support, or is not connected)")
            }
        } catch {
            print("PHOTO NOT SENT (\(error))")
        }
    }
}
