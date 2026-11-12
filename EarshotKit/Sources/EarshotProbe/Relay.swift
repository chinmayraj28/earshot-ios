// Relay support for earshot-probe, kept apart from main.swift so it stays easy to read.
//
//   --carry friends   (default) take part in relaying: carry sealed messages between contacts
//   --carry off       take no part: announce no relay-v1, carry nothing
//
// So a Mac can be the friend in the middle between two iPhones that are out of range of each
// other. Every relay step is printed as a RELAY line. Envelopes are named by the first 4 bytes of
// their ID (a hash of the ciphertext), so the same envelope can be followed on each device.
// It prints the name of the contact an envelope was handed to or opened from (this is a developer
// tool on your own Mac), never message text or keys, and it cannot know whom a carried envelope is for.

import EarshotKit
import Foundation

@MainActor
enum ProbeRelay {
    static var mode: CarryMode = .friends

    /// Handles `--carry <mode>`. Returns false if the flag is not ours.
    static func parse(_ argument: String, next: () -> String?) -> Bool {
        guard argument == "--carry" else { return false }
        guard let value = next(), let parsed = CarryMode(rawValue: value) else {
            print("--carry needs one of: \(CarryMode.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(64)
        }
        mode = parsed
        return true
    }

    static func attach(to messenger: Messenger) {
        messenger.setCarryMode(mode)
        messenger.onRelayActivity = { activity in
            let name = { (id: ContactID) in messenger.contact(id)?.displayName ?? "?" }
            switch activity {
            case .keysReady(let id): print("RELAY keys ready with \(name(id))")
            case .sealed(let envelope, let bytes): print("RELAY sealed \(envelope) (\(bytes) bytes)")
            case .handedOver(let envelope, let to): print("RELAY handed \(envelope) to \(name(to))")
            case .carried(let envelope, let bytes): print("RELAY carrying \(envelope) (\(bytes) bytes) – now \(messenger.carriedMailCount) carried")
            case .opened(let envelope, let from): print("RELAY opened \(envelope) from \(name(from))")
            case .refused(let envelope, let reason): print("RELAY refused \(envelope): \(reason)")
            case .receiptReleased: print("RELAY receipt released")
            case .receiptReceived(let deleted, let delivered):
                print("RELAY receipt received\(deleted ? " – carried copy deleted, now \(messenger.carriedMailCount) carried" : "")\(delivered ? " – own message delivered" : "")")
            case .expired(let count): print("RELAY \(count) expired")
            }
        }
        print("RELAY carry mode \(mode.rawValue)")
    }
}
