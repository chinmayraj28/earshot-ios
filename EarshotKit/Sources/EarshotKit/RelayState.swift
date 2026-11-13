import CryptoKit
import Foundation

// Everything the relay layer remembers, and the rules for changing it. Pure state: no radio,
// no timers, no files. `Messenger+Relay.swift` drives it and saves it.

/// Keys and this phone's own sealed messages. Saved as JSON (`relay-keys`). Small.
struct RelayKeys: Codable, Equatable {
    var version = 1
    var carryMode: CarryMode = .friends
    /// Per contact (by `ContactID.rawValue`).
    var pairs: [String: PairKeys] = [:]
    /// This phone's own messages that are sealed for relaying and not yet confirmed.
    var outbox: [RelayOutgoing] = []
}

struct PairKeys: Codable, Equatable {
    /// The chain for messages to this contact. Set only once the contact confirmed the generation.
    var send: SendChain?
    /// Chains for messages from this contact, newest last. Older generations stay for a grace period
    /// because envelopes sealed under them may still be on their way.
    var receive: [ReceiveChain] = []
}

struct SendChain: Codable, Equatable {
    var generation: Data
    /// The index the next message will use, and its chain key. Earlier keys are gone.
    var index: UInt32
    var key: Data
    /// One past the highest index a receipt has come back for. The recipient can recognise
    /// indexes up to `floor + lookahead - 1`, so nothing beyond that is sealed.
    var floor: UInt32 = 0
}

struct ReceiveChain: Codable, Equatable {
    var generation: Data
    var createdAt: Date
    /// When the contact showed it sends under this generation (`relayConfirmed`, or an envelope
    /// under it opened). Older generations retire only a grace period after a *confirmed* newer one,
    /// so a contact that never learned about a newer generation keeps being understood.
    var peerConfirmedAt: Date?
    /// The lowest index not yet received or skipped, and its chain key.
    var base: UInt32
    var key: Data
    /// Keys for indexes below `base` that have not arrived yet (they may still be on their way).
    var skipped: [SkippedKey] = []
}

struct SkippedKey: Codable, Equatable {
    var index: UInt32
    var messageKey: Data
    var receiptSecret: Data
    var tag: Data
    var expires: Date
}

/// One of this phone's own messages, sealed for a contact who is out of range.
struct RelayOutgoing: Codable, Equatable {
    var messageID: UUID
    var contact: ContactID
    var envelope: Data
    /// Kept so the sender can release it after a direct delivery and clear the relayed copies.
    var receiptSecret: Data
    var generation: Data
    var index: UInt32
    /// Contacts whose phones took a copy. Only on the sender's own phone, deleted with the entry.
    var carriers: [ContactID] = []
    /// Past its expiry: no longer offered. The message itself still waits for a direct link.
    var expired = false

    /// Stored when sealed, so lookups never hash envelopes again.
    var id: Data?
    var envelopeID: Data { id ?? RelayCrypto.envelopeID(envelope) }
    var receiptHash: Data { Data(envelope[envelope.startIndex + 17 ..< envelope.startIndex + 33]) }
}

/// A sealed envelope this phone carries for someone else. It never knows whose it is.
struct CarriedEnvelope: Equatable {
    var envelope: RelayEnvelope
    var id: Data
    /// How many phones it has been handed to from here.
    var handedOut: Int = 0
}

struct SeenEntry: Equatable {
    var receiptHash: Data
    var expires: Date
}

struct TagRef: Equatable {
    var contact: String
    var generation: Data
    var index: UInt32
    var skipped: Bool
}

enum RelayOpenResult: Equatable {
    /// Not addressed to this phone (as far as it can tell).
    case notMine
    /// Addressed here but refused. The reason is for diagnostics only.
    case rejected(String)
    case opened(contact: ContactID, inner: RelayInner, receiptSecret: Data)
}

struct RelayState: Equatable {
    var keys = RelayKeys() {
        didSet { rebuildOutboxIndex() }
    }
    /// Envelopes carried for others, oldest first. Setting it replaces everything (tests do this);
    /// the relay code itself changes `carriedStorage` and keeps the lookup tables up to date.
    var carried: [CarriedEnvelope] {
        get { carriedStorage }
        set {
            carriedStorage = newValue
            reindexCarried()
        }
    }
    private var carriedStorage: [CarriedEnvelope] = []
    private(set) var carriedBytes = 0
    /// Lookup tables, rebuilt whenever `keys` or `carried` change. Never saved.
    private var outboxIDs: Set<Data> = []
    private var outboxMessageIDs: Set<UUID> = []
    private var carriedIndex: [Data: Int] = [:]
    /// Which contact handed over each carried envelope (by `ContactID.rawValue`). In memory only,
    /// never saved: it enforces the per-contact share and is forgotten on restart.
    private(set) var depositors: [Data: String] = [:]
    /// True when a relay-keys store existed but could not be read. Relaying then stays off and the
    /// store is not overwritten (see `Messenger.loadRelay`).
    private(set) var keysUnreadable = false
    var seen: [Data: SeenEntry] = [:]
    private var seenOrder: [Data] = []
    private var seenReceiptHashes: [Data: Int] = [:]
    /// Released receipt secrets this phone passes on, with when it stops doing so.
    private(set) var receipts: [Data: Date] = [:]
    /// Hashes of `receipts`, so an envelope already confirmed delivered is never carried again.
    private var receiptHashes: Set<Data> = []
    /// Tag → which contact, generation and index it belongs to. Rebuilt from `keys`, never saved.
    private(set) var tagIndex: [Data: TagRef] = [:]
    private var tagsByContact: [String: [Data]] = [:]

    init() {}

    // MARK: Loading and saving

    init(keysData: Data?, carryData: Data?) {
        if let keysData {
            if let decoded = try? JSONDecoder().decode(RelayKeys.self, from: keysData), decoded.version == 1 {
                keys = decoded
            } else {
                // Fail closed: an unreadable store may have said "off".
                keys.carryMode = .off
                keysUnreadable = true
            }
        }
        if let carryData { loadCarry(carryData) }
        rebuildIndexes()
        for contact in keys.pairs.keys { reindex(contact) }
    }

    /// Property observers do not run inside initialisers, so the lookup tables are built here too.
    private mutating func rebuildIndexes() {
        rebuildOutboxIndex()
        reindexCarried()
    }

    private mutating func rebuildOutboxIndex() {
        outboxIDs = Set(keys.outbox.map(\.envelopeID))
        outboxMessageIDs = Set(keys.outbox.map(\.messageID))
    }

    /// Rebuilds the carried lookup tables (after removals, which shift positions).
    private mutating func reindexCarried() {
        var index: [Data: Int] = [:]
        index.reserveCapacity(carriedStorage.count)
        var bytes = 0
        for (offset, item) in carriedStorage.enumerated() {
            if index[item.id] == nil { index[item.id] = offset }
            bytes += item.envelope.bytes.count
        }
        carriedIndex = index
        carriedBytes = bytes
        if depositors.count > index.count || depositors.keys.contains(where: { index[$0] == nil }) {
            depositors = depositors.filter { index[$0.key] != nil }
        }
    }

    private mutating func appendCarried(_ item: CarriedEnvelope) {
        carriedIndex[item.id] = carriedStorage.count
        carriedStorage.append(item)
        carriedBytes += item.envelope.bytes.count
    }

    /// Removes matching carried envelopes. Returns how many went.
    @discardableResult
    private mutating func removeCarried(where matches: (CarriedEnvelope) -> Bool) -> Int {
        let before = carriedStorage.count
        carriedStorage.removeAll(where: matches)
        guard carriedStorage.count != before else { return 0 }
        reindexCarried()
        return before - carriedStorage.count
    }

    func encodedKeys() -> Data { (try? JSONEncoder().encode(keys)) ?? Data() }

    /// Compact binary: `"ESC1"`, then carried envelopes (u16 handedOut, u16 length, bytes),
    /// seen entries (8-byte ID, 16-byte receipt hash, u32 expiry as Unix seconds) and receipts
    /// (16-byte secret, u32 expiry), each list prefixed with a u32 count.
    func encodedCarry() -> Data {
        var out = Data("ESC1".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }
        func time(_ d: Date) { u32(UInt32(clamping: Int(d.timeIntervalSince1970))) }
        u32(UInt32(carried.count))
        for item in carried {
            u16(UInt16(clamping: item.handedOut))
            u16(UInt16(item.envelope.bytes.count))
            out.append(item.envelope.bytes)
        }
        u32(UInt32(seenOrder.count))
        for id in seenOrder {
            guard let entry = seen[id] else { continue }
            out.append(id); out.append(entry.receiptHash); time(entry.expires)
        }
        u32(UInt32(receipts.count))
        for (secret, expires) in receipts { out.append(secret); time(expires) }
        return out
    }

    private mutating func loadCarry(_ data: Data) {
        var bytes = [UInt8](data)[...]
        func take(_ n: Int) -> [UInt8]? {
            guard bytes.count >= n else { return nil }
            defer { bytes = bytes.dropFirst(n) }
            return Array(bytes.prefix(n))
        }
        func u32() -> UInt32? { take(4).map { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } }
        func u16() -> Int? { take(2).map { Int($0[0]) << 8 | Int($0[1]) } }
        guard take(4) == Array("ESC1".utf8), let carriedCount = u32() else { return }
        var carried: [CarriedEnvelope] = []
        for _ in 0..<min(carriedCount, UInt32(RelayLimits.carryMaxEnvelopes)) {
            guard let handed = u16(), let length = u16(), let raw = take(length),
                  let envelope = RelayEnvelope(parsing: Data(raw)) else { return }
            carried.append(CarriedEnvelope(envelope: envelope, id: envelope.id, handedOut: handed))
        }
        guard let seenCount = u32() else { return }
        var seenList: [(Data, SeenEntry)] = []
        for _ in 0..<min(seenCount, UInt32(RelayLimits.maxSeen)) {
            guard let id = take(8), let hash = take(16), let expires = u32() else { return }
            seenList.append((Data(id), SeenEntry(receiptHash: Data(hash), expires: Date(timeIntervalSince1970: TimeInterval(expires)))))
        }
        guard let receiptCount = u32() else { return }
        var receipts: [Data: Date] = [:]
        for _ in 0..<min(receiptCount, UInt32(RelayLimits.maxReceipts)) {
            guard let secret = take(16), let expires = u32() else { return }
            receipts[Data(secret)] = Date(timeIntervalSince1970: TimeInterval(expires))
        }
        self.carried = carried
        for (id, entry) in seenList { insertSeen(id, entry) }
        self.receipts = receipts
        receiptHashes = Set(receipts.keys.map(RelayCrypto.receiptHash))
    }

    // MARK: Generations

    /// Installs the incoming chain of a new generation right away (the contact may start using it
    /// as soon as it has our `relaySync`) and returns the outgoing chain, which the caller keeps
    /// until the contact's `relaySync` proves it derived the same root.
    mutating func installGeneration(contact: ContactID, root: SymmetricKey, ownIdentityKey: Data,
                                    peerIdentityKey: Data, now: Date) -> (generation: Data, send: SendChain) {
        let generation = RelayCrypto.generationID(root: root)
        let send = SendChain(generation: generation, index: 0,
                             key: RelayCrypto.chainStart(root: root, sender: ownIdentityKey, recipient: peerIdentityKey))
        var pair = keys.pairs[contact.rawValue] ?? PairKeys()
        if !pair.receive.contains(where: { $0.generation == generation }) {
            pair.receive.append(ReceiveChain(generation: generation, createdAt: now, base: 0,
                                             key: RelayCrypto.chainStart(root: root, sender: peerIdentityKey,
                                                                         recipient: ownIdentityKey)))
        }
        keys.pairs[contact.rawValue] = pair
        pruneGenerations(contact.rawValue, now: now)
        reindex(contact.rawValue)
        return (generation, send)
    }

    /// The contact derived the same generation: messages to them use it from now on.
    /// A repeated confirmation of the current generation changes nothing (the index is kept).
    mutating func confirm(contact: ContactID, send: SendChain) {
        var pair = keys.pairs[contact.rawValue] ?? PairKeys()
        guard pair.send?.generation != send.generation else { return }
        pair.send = send
        keys.pairs[contact.rawValue] = pair
    }

    func hasConfirmedGeneration(_ contact: ContactID) -> Bool { keys.pairs[contact.rawValue]?.send != nil }

    /// The contact says (`relayConfirmed`) or shows (an envelope opened) that it sends under this generation.
    mutating func markPeerConfirmed(contact: String, generation: Data, now: Date) {
        guard var pair = keys.pairs[contact],
              let index = pair.receive.firstIndex(where: { $0.generation == generation }),
              pair.receive[index].peerConfirmedAt == nil else { return }
        pair.receive[index].peerConfirmedAt = now
        keys.pairs[contact] = pair
    }

    /// Drops the keys for one contact in both directions (blocked: nothing more is sealed for them
    /// or opened from them). They come back only with the next direct link after unblocking.
    mutating func dropKeys(contact: ContactID) {
        keys.pairs[contact.rawValue] = nil
        reindex(contact.rawValue)
    }

    /// Whether a message to this contact could be sealed right now, ignoring its size.
    func canSeal(to contact: ContactID) -> Bool {
        guard let send = keys.pairs[contact.rawValue]?.send else { return false }
        return send.index < send.floor &+ UInt32(RelayLimits.lookahead)
            && outstandingCount(for: contact) < RelayLimits.maxOutstandingPerContact
            && outstandingCount() < RelayLimits.maxOutstandingTotal
    }

    /// Retires old generations and expired skipped keys. Returns true if anything changed.
    @discardableResult
    private mutating func pruneGenerations(_ contact: String, now: Date) -> Bool {
        guard var pair = keys.pairs[contact] else { return false }
        let before = pair
        var sorted = pair.receive.sorted { $0.createdAt < $1.createdAt }
        // Retire a generation only once the contact has shown it sends under a NEWER one, and that
        // was more than the grace period ago (envelopes sealed under the old one may still travel).
        // A contact that never learned about a newer generation keeps using the old one, so the old
        // one must stay: this is what keeps a one-sided confirmation from silently breaking relaying.
        if let newestConfirmed = sorted.lastIndex(where: { $0.peerConfirmedAt != nil }),
           let confirmedAt = sorted[newestConfirmed].peerConfirmedAt,
           now.timeIntervalSince(confirmedAt) > RelayLimits.generationGrace {
            sorted.removeFirst(newestConfirmed)
        }
        // Too many: drop the oldest, but never the newest confirmed generation or the newest one.
        while sorted.count > RelayLimits.maxReceiveGenerations {
            let newestConfirmed = sorted.lastIndex(where: { $0.peerConfirmedAt != nil })
            guard let victim = sorted.indices.first(where: { $0 != newestConfirmed && $0 != sorted.count - 1 }) else { break }
            sorted.remove(at: victim)
        }
        pair.receive = sorted
        for index in pair.receive.indices {
            pair.receive[index].skipped.removeAll { $0.expires <= now }
        }
        guard pair != before else { return false }
        keys.pairs[contact] = pair
        return true
    }

    // MARK: Sealing (sender)

    func outstandingCount(for contact: ContactID? = nil) -> Int {
        keys.outbox.filter { !$0.expired && (contact == nil || $0.contact == contact) }.count
    }

    func hasOutboxEntry(for messageID: UUID) -> Bool { outboxMessageIDs.contains(messageID) }

    /// Seals a text message for a contact, advancing the chain. Returns nil (and changes nothing)
    /// when there is no confirmed generation, a cap is reached, or the text does not fit 8,192 bytes.
    mutating func seal(text: String, messageID: UUID, sentAt: Date, to contact: ContactID, now: Date,
                       nonce: Data? = nil) -> RelayOutgoing? {
        guard var pair = keys.pairs[contact.rawValue], var send = pair.send,
              send.index < send.floor &+ UInt32(RelayLimits.lookahead),
              outstandingCount(for: contact) < RelayLimits.maxOutstandingPerContact,
              outstandingCount() < RelayLimits.maxOutstandingTotal else { return nil }
        let step = RelayCrypto.step(send.key)
        let inner = RelayInner(messageID: messageID, sentAt: UInt64(max(sentAt.timeIntervalSince1970, 0) * 1000), text: text)
        guard let envelope = try? RelayEnvelope.seal(inner, step: step, expiresHour: RelayEnvelope.expiresHour(at: now),
                                                     nonce: nonce) else { return nil }
        let entry = RelayOutgoing(messageID: messageID, contact: contact, envelope: envelope.bytes,
                                  receiptSecret: step.receiptSecret, generation: send.generation, index: send.index,
                                  id: envelope.id)
        send.index += 1
        send.key = step.next
        pair.send = send
        keys.pairs[contact.rawValue] = pair
        keys.outbox.append(entry)
        return entry
    }

    // MARK: Opening (recipient)

    /// Tries an envelope against this phone's tag table. Keys are only used up when the
    /// envelope decrypts: junk that copies a real tag fails and leaves the slot free.
    mutating func open(_ envelope: RelayEnvelope, now: Date) -> RelayOpenResult {
        guard let ref = tagIndex[envelope.tag],
              var pair = keys.pairs[ref.contact],
              let chainIndex = pair.receive.firstIndex(where: { $0.generation == ref.generation }) else { return .notMine }
        var chain = pair.receive[chainIndex]

        let messageKey: SymmetricKey
        let receiptSecret: Data
        var newSkipped: [SkippedKey] = []
        var newBase = chain.base
        var newKey = chain.key
        if ref.skipped {
            guard let skipped = chain.skipped.first(where: { $0.index == ref.index }) else { return .notMine }
            messageKey = SymmetricKey(data: skipped.messageKey)
            receiptSecret = skipped.receiptSecret
        } else {
            guard ref.index >= chain.base else { return .notMine }
            var key = chain.key
            var index = chain.base
            while index < ref.index {
                let step = RelayCrypto.step(key)
                newSkipped.append(SkippedKey(index: index, messageKey: step.messageKey.withUnsafeBytes { Data($0) },
                                             receiptSecret: step.receiptSecret, tag: step.tag,
                                             expires: now.addingTimeInterval(RelayLimits.skippedKeyLifetime)))
                key = step.next
                index += 1
            }
            let step = RelayCrypto.step(key)
            messageKey = step.messageKey
            receiptSecret = step.receiptSecret
            newBase = ref.index + 1
            newKey = step.next
        }
        guard RelayCrypto.receiptHash(receiptSecret) == envelope.receiptHash,
              let plain = try? envelope.open(with: messageKey) else { return .rejected("did not decrypt") }

        // Genuine: use the slot up whatever the contents, so it can never be replayed.
        if ref.skipped {
            chain.skipped.removeAll { $0.index == ref.index }
        } else {
            chain.skipped.append(contentsOf: newSkipped)
            chain.base = newBase
            chain.key = newKey
        }
        if chain.skipped.count > RelayLimits.maxSkippedKeys {
            chain.skipped.sort { $0.index < $1.index }
            chain.skipped.removeFirst(chain.skipped.count - RelayLimits.maxSkippedKeys)
        }
        if chain.peerConfirmedAt == nil { chain.peerConfirmedAt = now }
        pair.receive[chainIndex] = chain
        keys.pairs[ref.contact] = pair
        reindex(ref.contact)

        guard let inner = try? RelayInner.decode(plain), !inner.text.isEmpty,
              inner.text.count <= Limits.maxMessageLength else { return .rejected("malformed contents") }
        let sentAt = TimeInterval(inner.sentAt) / 1000
        let t = now.timeIntervalSince1970
        guard sentAt >= t - RelayLimits.maxSentAtAge, sentAt <= t + RelayLimits.maxSentAtFuture else {
            return .rejected("too old or from the future")
        }
        return .opened(contact: ContactID(rawValue: ref.contact), inner: inner, receiptSecret: receiptSecret)
    }

    /// Rebuilds the tag table for one contact: the skipped keys plus the next `lookahead`
    /// indexes of every incoming chain.
    private mutating func reindex(_ contact: String) {
        for tag in tagsByContact[contact] ?? [] { tagIndex[tag] = nil }
        var tags: [Data] = []
        for chain in keys.pairs[contact]?.receive ?? [] {
            for skipped in chain.skipped {
                tagIndex[skipped.tag] = TagRef(contact: contact, generation: chain.generation, index: skipped.index, skipped: true)
                tags.append(skipped.tag)
            }
            var key = chain.key
            for offset in 0..<UInt32(RelayLimits.lookahead) {
                let (tag, next) = RelayCrypto.tagAndNext(key)
                tagIndex[tag] = TagRef(contact: contact, generation: chain.generation, index: chain.base + offset, skipped: false)
                tags.append(tag)
                key = next
            }
        }
        tagsByContact[contact] = tags.isEmpty ? nil : tags
    }

    // MARK: Carrying (for others)

    func isSeen(_ id: Data) -> Bool { seen[id] != nil }

    func isHeld(_ id: Data) -> Bool { carriedIndex[id] != nil || outboxIDs.contains(id) }


    /// Remembers an envelope ID. Returns false if it was already known. When the list is full the
    /// oldest entry is forgotten: overload can only make a phone take a duplicate, never refuse new mail.
    @discardableResult
    mutating func markSeen(_ id: Data, receiptHash: Data, now: Date) -> Bool {
        guard seen[id] == nil else { return false }
        insertSeen(id, SeenEntry(receiptHash: receiptHash, expires: now.addingTimeInterval(RelayLimits.seenLifetime)))
        while seenOrder.count > RelayLimits.maxSeen { removeSeen(seenOrder.removeFirst()) }
        return true
    }

    private mutating func insertSeen(_ id: Data, _ entry: SeenEntry) {
        guard seen[id] == nil else { return }
        seen[id] = entry
        seenOrder.append(id)
        seenReceiptHashes[entry.receiptHash, default: 0] += 1
    }

    private mutating func removeSeen(_ id: Data) {
        guard let entry = seen.removeValue(forKey: id) else { return }
        let count = (seenReceiptHashes[entry.receiptHash] ?? 1) - 1
        seenReceiptHashes[entry.receiptHash] = count > 0 ? count : nil
    }

    /// Stores an envelope for someone else if there is room. When full, makes room only by
    /// dropping an envelope that has already been handed on at least twice.
    /// What one contact's deposits currently take up. "" = envelopes whose depositor is not known
    /// (restored from disk after a restart).
    func usage(of depositor: String) -> (count: Int, bytes: Int) {
        var count = 0, bytes = 0
        for item in carriedStorage where (depositors[item.id] ?? "") == depositor {
            count += 1
            bytes += item.envelope.bytes.count
        }
        return (count, bytes)
    }

    /// Stores an envelope for someone else.
    ///
    /// - Each contact may fill at most a fifth of the store (`perDepositorMaxBytes`) and 250 envelopes.
    /// - When the store is full, room is made by dropping from whoever holds the most space (never
    ///   from the contact depositing now). After a restart the phone no longer knows who gave what;
    ///   those envelopes count as one holder, and are the first to go once they are the largest. So a
    ///   contact can never push out the share of others, restart or not.
    mutating func carry(_ envelope: RelayEnvelope, from depositor: ContactID? = nil) -> Bool {
        let id = envelope.id
        guard !isHeld(id), !receiptHashes.contains(envelope.receiptHash) else { return false }
        let who = depositor?.rawValue ?? ""
        let size = envelope.bytes.count
        if depositor != nil {
            let mine = usage(of: who)
            guard mine.count < RelayLimits.perDepositorMax, mine.bytes + size <= RelayLimits.perDepositorMaxBytes else {
                return false
            }
        }
        if carriedStorage.count >= RelayLimits.carryMaxEnvelopes || carriedBytes + size > RelayLimits.carryMaxBytes {
            var byHolder: [String: Int] = [:]
            for item in carriedStorage { byHolder[depositors[item.id] ?? "", default: 0] += item.envelope.bytes.count }
            var count = carriedStorage.count, total = carriedBytes
            var victims: Set<Int> = []
            while count >= RelayLimits.carryMaxEnvelopes || total + size > RelayLimits.carryMaxBytes {
                guard let largest = byHolder.filter({ $0.key != who && $0.value > 0 }).max(by: { $0.value < $1.value })?.key,
                      let victim = carriedStorage.indices.filter({ !victims.contains($0) && (depositors[carriedStorage[$0].id] ?? "") == largest })
                        .max(by: { carriedStorage[$0].handedOut < carriedStorage[$1].handedOut }) else { return false }
                victims.insert(victim)
                let bytes = carriedStorage[victim].envelope.bytes.count
                byHolder[largest, default: 0] -= bytes
                total -= bytes
                count -= 1
            }
            carriedStorage = carriedStorage.enumerated().filter { !victims.contains($0.offset) }.map(\.element)
            reindexCarried()
        }
        appendCarried(CarriedEnvelope(envelope: envelope, id: id))
        if depositor != nil { depositors[id] = who }
        return true
    }

    /// Deletes everything carried for others and what was remembered about it (seen envelope IDs
    /// and receipts). Own messages and keys stay.
    mutating func eraseCarried() {
        carried = []
        seen.removeAll()
        seenOrder.removeAll()
        seenReceiptHashes.removeAll()
        receipts.removeAll()
        receiptHashes.removeAll()
    }

    /// What can be offered right now: carried envelopes and own sealed messages that are fresh
    /// and have not yet been handed out `maxHandOuts` times.
    func offerable(now: Date) -> [(id: Data, size: Int)] {
        let carriedItems = carried.filter { $0.envelope.isFresh(at: now) && $0.handedOut < RelayLimits.maxHandOuts }
            .map { ($0.id, $0.envelope.bytes.count) }
        let own = keys.outbox.filter {
            !$0.expired && $0.carriers.count < RelayLimits.maxHandOuts
                && (RelayEnvelope(parsing: $0.envelope)?.isFresh(at: now) ?? false)
        }.map { ($0.envelopeID, $0.envelope.count) }
        return carriedItems + own
    }

    /// The envelope to hand over, or nil if it is gone, expired or already handed out `maxHandOuts` times.
    func envelope(withID id: Data) -> Data? {
        if let index = carriedIndex[id] {
            return carried[index].handedOut < RelayLimits.maxHandOuts ? carried[index].envelope.bytes : nil
        }
        guard outboxIDs.contains(id) else { return nil }
        return keys.outbox.first {
            $0.envelopeID == id && !$0.expired && $0.carriers.count < RelayLimits.maxHandOuts
        }?.envelope
    }

    /// For one of this phone's own sealed messages: whom it is for.
    func recipient(ofOwn id: Data) -> ContactID? {
        guard outboxIDs.contains(id) else { return nil }
        return keys.outbox.first { $0.envelopeID == id }?.contact
    }

    /// The size of an envelope this phone holds, for keeping each request round small.
    func size(ofHeld id: Data) -> Int? {
        if let index = carriedIndex[id] { return carried[index].envelope.bytes.count }
        return keys.outbox.first { $0.envelopeID == id }?.envelope.count
    }

    /// Counts a hand-over. For own messages returns the message ID if the carrier is new.
    @discardableResult
    mutating func recordHandOut(_ id: Data, to contact: ContactID) -> UUID? {
        if let index = carriedIndex[id] {
            carriedStorage[index].handedOut += 1
            return nil
        }
        guard let index = keys.outbox.firstIndex(where: { $0.envelopeID == id }),
              !keys.outbox[index].carriers.contains(contact) else { return nil }
        keys.outbox[index].carriers.append(contact)
        return keys.outbox[index].messageID
    }

    // MARK: Receipts

    struct ReceiptEffect: Equatable {
        /// The receipt matched something this phone knows, so it is kept and passed on.
        var known = false
        var isNew = false
        var deletedCarried = false
        /// Own messages now confirmed delivered.
        var delivered: [RelayOutgoing] = []
    }

    /// Applies a receipt secret from anyone. Only a receipt whose hash matches an envelope this
    /// phone holds, sent, or has seen is kept and passed on; anything else is ignored.
    mutating func applyReceipt(_ secret: Data, now: Date) -> ReceiptEffect {
        var effect = ReceiptEffect()
        guard secret.count == 16 else { return effect }
        let hash = RelayCrypto.receiptHash(secret)
        let delivered = keys.outbox.filter { $0.receiptHash == hash }
        if !delivered.isEmpty {
            effect.delivered = delivered
            keys.outbox.removeAll { $0.receiptHash == hash }
            for entry in delivered { raiseFloor(entry) }
        }
        effect.deletedCarried = removeCarried { $0.envelope.receiptHash == hash } > 0
        effect.known = !delivered.isEmpty || effect.deletedCarried || seenReceiptHashes[hash] != nil
        if effect.known { effect.isNew = keepReceipt(secret, now: now) }
        return effect
    }

    /// Keeps a receipt this phone made itself (it opened the message, or delivered it directly).
    @discardableResult
    mutating func releaseOwnReceipt(_ secret: Data, now: Date) -> ReceiptEffect {
        var effect = applyReceipt(secret, now: now)
        if !effect.known { effect.known = true; effect.isNew = keepReceipt(secret, now: now) }
        return effect
    }

    private mutating func keepReceipt(_ secret: Data, now: Date) -> Bool {
        guard receipts[secret] == nil else { return false }
        receipts[secret] = now.addingTimeInterval(RelayLimits.receiptLifetime)
        receiptHashes.insert(RelayCrypto.receiptHash(secret))
        while receipts.count > RelayLimits.maxReceipts,
              let oldest = receipts.min(by: { $0.value < $1.value })?.key {
            receipts[oldest] = nil
            receiptHashes.remove(RelayCrypto.receiptHash(oldest))
        }
        return true
    }

    private mutating func raiseFloor(_ entry: RelayOutgoing) {
        guard var pair = keys.pairs[entry.contact.rawValue], var send = pair.send,
              send.generation == entry.generation else { return }
        send.floor = max(send.floor, entry.index &+ 1)
        pair.send = send
        keys.pairs[entry.contact.rawValue] = pair
    }

    /// Removes this phone's own sealed copy of a message (delivered directly, deleted, contact removed).
    /// Returns its receipt secret so the caller can release it and clear the copies friends carry.
    mutating func removeOutbox(messageID: UUID) -> Data? {
        guard let index = keys.outbox.firstIndex(where: { $0.messageID == messageID }) else { return nil }
        // No raiseFloor here: the recipient's chain did not move just because this phone deleted its
        // copy (or delivered directly). Only a receipt proves where the recipient's window is.
        return keys.outbox.remove(at: index).receiptSecret
    }

    // MARK: Housekeeping

    /// Drops whatever has expired. Returns how many envelopes (carried or own) expired.
    mutating func purge(now: Date) -> Int {
        var expired = removeCarried { !$0.envelope.isFresh(at: now) }
        for index in keys.outbox.indices where !keys.outbox[index].expired {
            if !(RelayEnvelope(parsing: keys.outbox[index].envelope)?.isFresh(at: now) ?? false) {
                keys.outbox[index].expired = true
                expired += 1
            }
        }
        for id in seen.keys where seen[id]!.expires <= now { removeSeen(id) }
        seenOrder.removeAll { seen[$0] == nil }
        receipts = receipts.filter { $0.value > now }
        receiptHashes = Set(receipts.keys.map(RelayCrypto.receiptHash))
        for contact in Array(keys.pairs.keys) where pruneGenerations(contact, now: now) {
            reindex(contact)
        }
        return expired
    }

    /// A contact was removed: forget their keys and this phone's sealed messages to them.
    /// Returns the receipt secrets of those messages, to clear the copies friends carry.
    mutating func forget(contact: ContactID) -> [Data] {
        keys.pairs[contact.rawValue] = nil
        reindex(contact.rawValue)
        let secrets = keys.outbox.filter { $0.contact == contact }.map(\.receiptSecret)
        keys.outbox.removeAll { $0.contact == contact }
        return secrets
    }

    /// Relaying switched off: no keys, nothing carried, nothing remembered. The setting stays.
    mutating func wipe() {
        let mode = keys.carryMode
        self = RelayState()
        keys.carryMode = mode
    }
}
