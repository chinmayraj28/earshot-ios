import Foundation

/// Whether this phone takes part in relaying ("friends carry for friends").
///
/// Modelled so that a later version can add an option for carrying strangers' mail; this
/// version has only these two.
public enum CarryMode: String, Codable, Sendable, CaseIterable {
    /// The phone takes no part in relaying at all: it announces no `relay-v1`, carries nothing
    /// for anyone, never hands your messages to anyone else, and keeps no relay keys. Your
    /// messages wait until the contact is in range, as in earlier versions.
    case off
    /// Your messages can travel through contacts' phones, and your phone carries sealed
    /// messages for your contacts (it cannot read them).
    case friends
}

/// What the relay layer did, for diagnostics (the probe prints these). Never contains message
/// text, names or keys. `envelope` is the first 4 bytes of the envelope ID (a hash of the
/// ciphertext), so the same envelope can be followed across devices in debug output.
public enum RelayActivity: Sendable, Equatable {
    /// Both phones on a direct link derived the same new relay keys.
    case keysReady(ContactID)
    /// One of your own messages was sealed into an envelope.
    case sealed(envelope: String, bytes: Int)
    /// Envelopes handed to a contact's phone on request.
    case handedOver(envelope: String, to: ContactID)
    /// An envelope for someone else is now carried by this phone.
    case carried(envelope: String, bytes: Int)
    /// An envelope addressed to this phone was opened.
    case opened(envelope: String, from: ContactID)
    /// An envelope was refused: malformed, expired, already seen, failed decryption, or no room.
    case refused(envelope: String, reason: String)
    /// This phone released a receipt (it received a message, or a message was delivered directly).
    case receiptReleased
    /// A receipt arrived. `deletedCarried`: a carried copy was deleted. `delivered`: one of your own
    /// messages is now confirmed delivered.
    case receiptReceived(deletedCarried: Bool, delivered: Bool)
    /// Carried envelopes or own relayed copies that passed their expiry.
    case expired(count: Int)
}

extension RelayActivity {
    /// One line for the system log: no contact IDs, names, text or keys.
    var logLine: String {
        switch self {
        case .keysReady: "keys ready"
        case .sealed(let envelope, let bytes): "sealed \(envelope) (\(bytes) bytes)"
        case .handedOver(let envelope, _): "handed over \(envelope)"
        case .carried(let envelope, let bytes): "carrying \(envelope) (\(bytes) bytes)"
        case .opened(let envelope, _): "opened \(envelope)"
        case .refused(let envelope, let reason): "refused \(envelope): \(reason)"
        case .receiptReleased: "receipt released"
        case .receiptReceived(let deleted, let delivered): "receipt received deleted=\(deleted) delivered=\(delivered)"
        case .expired(let count): "\(count) expired"
        }
    }
}

/// Every number that bounds relaying. See section 7 of the design (in `docs/HOW_IT_WORKS.md`).
public enum RelayLimits {
    /// An envelope is kept by carriers for at most this long.
    public static let lifetimeHours = 48
    /// Expiry is rounded down to this many hours, so it says little about when it was made.
    static let expiryStepHours = 6
    /// How many messages ahead of the last one received the recipient can recognise.
    static let lookahead = 256
    /// Keys kept for messages that were skipped (still on their way), per contact.
    static let maxSkippedKeys = 1000
    static let skippedKeyLifetime: TimeInterval = 7 * 86_400
    /// An older generation of keys stays usable for incoming mail this long after a newer one exists.
    static let generationGrace: TimeInterval = 7 * 86_400
    static let maxReceiveGenerations = 6
    /// Own messages sealed and not yet confirmed, per contact and in total.
    public static let maxOutstandingPerContact = 200
    public static let maxOutstandingTotal = 500
    /// Entries per offer message, envelopes asked for at a time, receipts per message.
    static let maxOfferEntries = 512
    static let wantBudget = 100
    static let maxReceiptsPerMessage = 512
    /// What this phone carries for others.
    public static let carryMaxEnvelopes = 1000
    public static let carryMaxBytes = 2 * 1024 * 1024
    /// At most this many carried envelopes, and this share of the store, from any one contact.
    static let perDepositorMax = 250
    static let perDepositorMaxBytes = carryMaxBytes / 5
    /// One request round asks for at most this many bytes of envelopes (and at most `wantBudget`
    /// envelopes), so at most this much is ever queued towards one phone per round.
    static let wantByteBudget = 64 * 1024
    /// Each phone hands each envelope to at most this many others.
    static let maxHandOuts = 8
    /// Envelope IDs remembered so the same envelope is not taken twice; and receipts kept to pass on.
    static let seenLifetime: TimeInterval = 72 * 3600
    static let maxSeen = 10_000
    static let receiptLifetime: TimeInterval = 72 * 3600
    static let maxReceipts = 4000
    /// The recipient refuses relayed messages that claim to be older or newer than this.
    static let maxSentAtAge: TimeInterval = 7 * 86_400
    static let maxSentAtFuture: TimeInterval = 86_400
}

/// Fixed-layout lists carried by the relay payloads (`Payload.relayOffer`, `relayWant`,
/// `relayReceipts`). Each is a single byte string: entries back to back, no separators.
enum RelayLists {
    /// One offer entry: envelope ID (8 bytes) + size code (1 byte: 0 = 512, 1 = 2,048, 2 = 8,192).
    static let offerEntryLength = 9

    static func sizeCode(_ size: Int) -> UInt8 { UInt8(RelayEnvelope.buckets.firstIndex(of: size) ?? 0) }

    static func encodeOffer(_ entries: [(id: Data, size: Int)]) -> Data {
        var out = Data()
        for entry in entries { out.append(entry.id); out.append(sizeCode(entry.size)) }
        return out
    }

    static func decodeOffer(_ data: Data) -> [(id: Data, size: Int)]? {
        let bytes = [UInt8](data)
        guard bytes.count % offerEntryLength == 0, bytes.count / offerEntryLength <= RelayLimits.maxOfferEntries else { return nil }
        var out: [(Data, Int)] = []
        for start in stride(from: 0, to: bytes.count, by: offerEntryLength) {
            let code = Int(bytes[start + 8])
            guard code < RelayEnvelope.buckets.count else { return nil }
            out.append((Data(bytes[start..<start + 8]), RelayEnvelope.buckets[code]))
        }
        return out
    }

    static func split(_ data: Data, width: Int, max: Int) -> [Data]? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, bytes.count % width == 0, bytes.count / width <= max else { return nil }
        return stride(from: 0, to: bytes.count, by: width).map { Data(bytes[$0..<$0 + width]) }
    }
}
