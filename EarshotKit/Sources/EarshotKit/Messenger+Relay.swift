import CryptoKit
import Foundation
import os

/// Relaying ("relay-v1"): friends carry sealed text messages for friends.
///
/// Asha and Ben are contacts but out of range of each other. Chidi is linked to both.
///
/// 1. **Keys.** The last time Asha and Ben were linked directly, both phones derived a fresh
///    generation of relay keys from that link's private key exchange and confirmed it to each
///    other with `relaySync` (see `RelayCrypto`).
/// 2. **Sealing.** Asha writes to Ben while he is not linked. Her phone seals the text in an
///    envelope only Ben's phone can open (`RelayEnvelope`). The message also stays in her normal
///    outbox, so if she meets Ben first it is delivered directly as before.
/// 3. **Carrying.** Over every link between two contacts that both announced `relay-v1`, each phone
///    offers the envelopes it holds (`relayOffer`); the other asks for the ones it has not seen
///    (`relayWant`) and receives them (`relayEnvelope`, then `relayDone`). What a phone asks for
///    never depends on whether an envelope is its own: it asks for every unseen one, up to a budget.
/// 4. **Opening.** Ben's phone recognises the one-time tag on the outside, opens the envelope,
///    stores the message, and releases a receipt secret (`relayReceipts`). Carriers that see it
///    delete their copy and pass it on. When it reaches Asha, her message shows Delivered.
///
/// Chidi's phone learns nothing about who wrote the message, who it is for, or what it says.
/// It never shows anything about carried mail, beyond counts in Settings.
extension Messenger {
    /// Per-link relay bookkeeping. Lives only as long as the link.
    struct LinkRelay {
        /// Both sides announced `relay-v1` on this link (and this phone was carrying when it did).
        var active = false
        /// The generation derived on this link, and its outgoing chain until the peer confirms it.
        var generation: Data?
        var pendingSend: SendChain?
        /// Envelope IDs offered to the peer on this link, and those already handed over on it.
        /// Each envelope is handed over at most once per link; asking again closes the link.
        var offered: Set<Data> = []
        var served: Set<Data> = []
        /// An offer was sent and the peer has not answered with a `relayWant` yet. No new offer
        /// goes out until it does, so offers can never pile up faster than the peer handles them.
        var offerPending = false
        /// The peer sent an offer and is owed a `relayWant` (possibly empty) in answer.
        var owesWant = false
        /// What the peer offered that this phone has not asked for yet, in the peer's order.
        var peerOffered: [(id: Data, size: Int)] = []
        /// Asked for and not yet received. An envelope that is not in here is a protocol violation.
        var outstanding: Set<Data> = []
        /// Receipt secrets the peer already has (sent by us or received from it).
        var receiptsKnown: Set<Data> = []
        /// When this phone last sent offers or receipts on this link (exchanges are spaced out).
        var lastExchange: ContinuousClock.Instant?
        /// Allowance for incoming relay control messages, separate from the text allowance.
        var budget = 0.0
        var budgetUpdated = ContinuousClock.now
    }

    static let relayKeysBlob = "relay-keys"
    static let relayCarryBlob = "relay-carry"

    // MARK: Public API

    /// True when a message to this contact can travel through friends' phones while you are apart:
    /// relaying is on and the two of you confirmed relay keys the last time you were linked directly.
    public func canRelay(to id: ContactID) -> Bool { relayContacts.contains(id) }

    /// Chooses whether this phone takes part in relaying. Takes effect at once: links are reopened
    /// so the new choice is announced. Switching off deletes every relay key, everything carried for
    /// others and this phone's own sealed copies (messages still wait for a direct link).
    /// Envelopes already handed to friends cannot be called back; they expire within 48 hours.
    public func setCarryMode(_ mode: CarryMode) {
        // An explicit choice also ends the "store unreadable" safety stop: from now on it is saved.
        let wasSuspended = relaySavesSuspended
        relaySavesSuspended = false
        guard mode != carryMode || wasSuspended else { return }
        carryMode = mode
        if mode == .off || wasSuspended { relay.wipe() }
        relay.keys.carryMode = mode
        relayUnpersisted.removeAll()
        saveRelayKeys()
        saveRelayCarry()
        refreshRelayState()
        restartIfRunning()
    }

    /// Deletes everything carried for others: the sealed envelopes, and the envelope IDs and receipts
    /// this phone remembered about them. Your own messages and relay keys are kept.
    public func eraseCarriedMail() {
        relay.eraseCarried()
        saveRelayCarry()
        refreshRelayState()
    }

    // MARK: Loading

    func loadRelay() {
        relay = RelayState(keysData: persistence.load(blob: Self.relayKeysBlob),
                           carryData: persistence.load(blob: Self.relayCarryBlob))
        carryMode = relay.keys.carryMode
        if relay.keysUnreadable {
            // Fail closed: the store may have said "off". Relaying stays off for this run and the
            // unreadable store is left untouched, so it loads normally next time (for example once the
            // phone has been unlocked). Choosing a setting explicitly ends this.
            relaySavesSuspended = true
        } else if relay.purge(now: configuration.now()) > 0 {
            saveRelayKeys()
            saveRelayCarry()
        }
        refreshRelayState()
    }

    /// The features this phone announces in its identity proof on every link.
    var announcedFeatures: [String] {
        var features = [Feature.photo]
        if carryMode != .off, configuration.announcesRelay { features.append(Feature.relay) }
        return features
    }

    // MARK: Links

    /// Called once a link to a saved contact is established (both identity proofs checked).
    func relayLinkEstablished(_ token: PeerToken) {
        guard var link = links[token], let id = link.contactID, let contact = contact(id) else { return }
        let secret = link.relaySecret
        link.relaySecret = nil
        link.relay.active = link.announcedRelay && carryMode != .off && link.peerFeatures.contains(Feature.relay)
        link.relay.budget = configuration.relayIncomingBurst
        link.relay.budgetUpdated = .now
        guard link.relay.active else {
            links[token] = link
            // A contact that stopped announcing relay-v1 on a direct link gets no more sealed mail.
            if carryMode != .off, !link.peerFeatures.contains(Feature.relay), relay.hasConfirmedGeneration(id) {
                var pair = relay.keys.pairs[id.rawValue]
                pair?.send = nil
                relay.keys.pairs[id.rawValue] = pair
                saveRelayKeys()
                refreshRelayState()
            }
            return
        }
        if let secret, let ephemerals = link.relayEphemerals,
           let root = RelayCrypto.root(sharedSecret: secret, localEphemeral: ephemerals.local,
                                       remoteEphemeral: ephemerals.remote, ownIdentityKey: identity.publicKey,
                                       peerIdentityKey: contact.identityKey) {
            let installed = relay.installGeneration(contact: id, root: root, ownIdentityKey: identity.publicKey,
                                                    peerIdentityKey: contact.identityKey, now: configuration.now())
            link.relay.generation = installed.generation
            link.relay.pendingSend = installed.send
        }
        link.relayEphemerals = nil
        links[token] = link
        if let generation = link.relay.generation {
            // The incoming chain must be safely stored before the contact may use it: `relaySync`
            // goes out only once the save has succeeded, and only on this same link.
            let linkID = link.id
            saveRelayKeys { messenger, stored in
                guard stored, messenger.links[token]?.id == linkID, messenger.links[token]?.relay.active == true else { return }
                try? messenger.send(.relaySync(generation), to: token)
            }
        }
        relayExchange(on: token)
    }

    // MARK: Sending own messages

    /// Seals every waiting text message to a contact who is not linked right now, has confirmed
    /// relay keys, and has no sealed copy yet. Called whenever that could have changed.
    func relaySealWaiting() {
        guard carryMode != .off else { return }
        let now = configuration.now()
        var sealed: [Data] = []
        for contact in contacts where !contact.isBlocked && relay.hasConfirmedGeneration(contact.id) {
            guard !links.values.contains(where: { $0.contactID == contact.id }) else { continue }
            for message in messages(for: contact.id) where message.direction == .outgoing && message.status == .waiting
                && message.photo == nil && !relay.hasOutboxEntry(for: message.id) {
                // A cap or the recipient's window stops sealing for this contact; a message that is
                // simply too large for the biggest envelope is skipped and waits for a direct link.
                guard relay.canSeal(to: contact.id) else { break }
                guard let entry = relay.seal(text: message.text, messageID: message.id, sentAt: message.timestamp,
                                             to: contact.id, now: now) else { continue }
                sealed.append(entry.envelopeID)
                relayActivity(.sealed(envelope: Self.short(entry.envelopeID), bytes: entry.envelope.count))
            }
        }
        guard !sealed.isEmpty else { return }
        // Write-ahead: an envelope is only offered once the advanced chain is safely stored, so an
        // index is never used twice (even then, the random nonce keeps the encryption safe).
        relayUnpersisted.formUnion(sealed)
        refreshRelayState()
        scheduleWriteAhead()
    }

    /// Saves newly sealed envelopes' chain state, then lets them be offered. Several messages sealed in
    /// a row (a backlog typed offline) share one save instead of encoding the store for each.
    func scheduleWriteAhead() {
        guard !relayWriteAheadScheduled else { return }
        relayWriteAheadScheduled = true
        after(configuration.relayWriteAheadDelay) { messenger in
            messenger.relayWriteAheadScheduled = false
            messenger.writeAheadNow()
        }
    }

    func writeAheadNow() {
        let pending = relayUnpersisted
        guard !pending.isEmpty else { return }
        saveRelayKeys { messenger, stored in
            guard stored else { return }
            messenger.relayUnpersisted.subtract(pending)
            messenger.scheduleRelaySync()
        }
    }

    /// A direct receipt arrived for one of our messages: drop its sealed copy and release the
    /// receipt secret so friends delete the copies they carry.
    func relayDeliveredDirectly(_ messageID: UUID) {
        guard let secret = relay.removeOutbox(messageID: messageID) else { return }
        markRelayDirty(keys: true)
        releaseReceipt(secret)
        refreshRelayState()
    }

    /// Messages were removed from this phone. Their sealed copies are dropped and their receipts
    /// released, which also asks carriers to delete them (a best-effort recall: a carrier that
    /// already handed one on cannot take it back).
    func relayForget(_ messages: [Message]) {
        var secrets: [Data] = []
        for message in messages where message.direction == .outgoing {
            if let secret = relay.removeOutbox(messageID: message.id) { secrets.append(secret) }
        }
        guard !secrets.isEmpty else { return }
        saveRelayKeys()
        secrets.forEach(releaseReceipt)
        refreshRelayState()
        for (token, link) in links where link.relay.active { relayExchange(on: token) }
    }

    /// A contact was removed or blocked: its keys go (nothing more is sealed for it or opened from
    /// it), and this phone's sealed copies to it are dropped and their receipts released, asking
    /// carriers to delete them. Copies a carrier already handed on cannot be called back.
    func relayForget(contact id: ContactID) {
        let secrets = relay.forget(contact: id)
        saveRelayKeys()
        secrets.forEach(releaseReceipt)
        refreshRelayState()
        // A recall is a rare, deliberate act: tell linked friends at once rather than at the next
        // paced exchange, so a friend about to meet that person deletes the copy first.
        if !secrets.isEmpty { for (token, link) in links where link.relay.active { relayExchange(on: token) } }
    }

    func relayEraseAll() {
        relay = RelayState()
        relay.keys.carryMode = carryMode
        relayUnpersisted.removeAll()
        relayKeysDirty = false
        relayCarryDirty = false
        refreshRelayState()
    }

    // MARK: The exchange between two linked contacts

    /// Sends this link what it has not seen yet: offers for new envelopes (unless an offer is still
    /// unanswered), and new receipts. Returns true if anything was sent.
    @discardableResult
    func relayExchange(on token: PeerToken) -> Bool {
        guard var link = links[token], link.relay.active, let peer = link.contactID else { return false }
        let now = configuration.now()
        if relay.purge(now: now) > 0 { refreshRelayState() }
        // Own sealed messages are not offered to the very contact they are for: that contact is linked
        // right now, so they go directly (in order); a relayed copy would only arrive out of order.
        let fresh = link.relay.offerPending ? [] : relay.offerable(now: now).filter {
            !link.relay.offered.contains($0.id) && !relayUnpersisted.contains($0.id)
                && relay.depositors[$0.id] != peer.rawValue && relay.recipient(ofOwn: $0.id) != peer
        }.shuffled()
        let receipts = relay.receipts.keys.filter { !link.relay.receiptsKnown.contains($0) }
        guard !fresh.isEmpty || !receipts.isEmpty else { return false }
        link.relay.offered.formUnion(fresh.map(\.id))
        link.relay.receiptsKnown.formUnion(receipts)
        link.relay.lastExchange = .now
        if !fresh.isEmpty { link.relay.offerPending = true }
        links[token] = link
        do {
            for start in stride(from: 0, to: fresh.count, by: RelayLimits.maxOfferEntries) {
                let slice = Array(fresh[start..<min(start + RelayLimits.maxOfferEntries, fresh.count)])
                try send(.relayOffer(RelayLists.encodeOffer(slice)), to: token)
            }
            for start in stride(from: 0, to: receipts.count, by: RelayLimits.maxReceiptsPerMessage) {
                let slice = receipts[start..<min(start + RelayLimits.maxReceiptsPerMessage, receipts.count)]
                try send(.relayReceipts(slice.reduce(Data(), +)), to: token)
            }
        } catch {
            drop(token, because: .protocolViolation)
        }
        return true
    }

    /// Runs exchanges on the relay links soon. Bursts collapse into one exchange, and each link gets
    /// at most one exchange per `relayMinExchangeInterval`, so an honest phone never sends relay
    /// control messages faster than a peer accepts them, however slow the link.
    func scheduleRelaySync(after delay: Duration? = nil) {
        guard !relaySyncScheduled else { return }
        relaySyncScheduled = true
        after(delay ?? configuration.relaySyncDelay) { messenger in
            messenger.relaySyncScheduled = false
            messenger.runDueRelayExchanges()
        }
    }

    private func runDueRelayExchanges() {
        var wait: Duration?
        for (token, link) in links where link.relay.active {
            if let last = link.relay.lastExchange {
                let since = ContinuousClock.now - last
                if since < configuration.relayMinExchangeInterval {
                    let remaining = configuration.relayMinExchangeInterval - since
                    wait = min(wait ?? remaining, remaining)
                    continue
                }
            }
            relayExchange(on: token)
        }
        if let wait { scheduleRelaySync(after: wait) }
    }

    func handleRelay(_ payload: Payload, from token: PeerToken) throws {
        guard let link = links[token], let peer = link.contactID else { return }
        // A phone that did not agree to relaying on this link must never send relay payloads.
        guard link.relay.active else { throw LinkFailure.protocolViolation }
        if case .relayEnvelope = payload {} else { try chargeRelayMessage(on: token) }
        switch payload {
        case .relaySync(let generation):
            guard generation.count == 8 else { throw LinkFailure.protocolViolation }
            guard generation == link.relay.generation, let chain = link.relay.pendingSend else { return }
            links[token]?.relay.pendingSend = nil
            relay.confirm(contact: peer, send: chain)
            saveRelayKeys()
            // Tell the contact we now seal under this generation, so it can retire older ones.
            try send(.relayConfirmed(generation), to: token)
            relayActivity(.keysReady(peer))
            refreshRelayState()

        case .relayConfirmed(let generation):
            guard generation.count == 8 else { throw LinkFailure.protocolViolation }
            relay.markPeerConfirmed(contact: peer.rawValue, generation: generation, now: configuration.now())
            markRelayDirty(keys: true)

        case .relayOffer(let data):
            guard let entries = RelayLists.decodeOffer(data) else { throw LinkFailure.protocolViolation }
            guard var current = links[token] else { return }
            var queued = Set(current.relay.peerOffered.map(\.id))
            for entry in entries where !relay.isSeen(entry.id) && !relay.isHeld(entry.id)
                && !current.relay.outstanding.contains(entry.id) && !queued.contains(entry.id) {
                guard current.relay.peerOffered.count < RelayLimits.maxOfferEntries * 4 else { break }
                current.relay.peerOffered.append(entry)
                queued.insert(entry.id)
            }
            current.relay.owesWant = true
            links[token] = current
            try requestMore(on: token)

        case .relayWant(let data):
            // An empty want answers an offer with "nothing needed".
            let ids = data.isEmpty ? [] : RelayLists.split(data, width: 8, max: RelayLimits.wantBudget)
            guard let ids, Set(ids).count == ids.count,
                  ids.allSatisfy({ link.relay.offered.contains($0) && !link.relay.served.contains($0) }),
                  ids.compactMap({ relay.size(ofHeld: $0) }).reduce(0, +)
                    <= RelayLimits.wantByteBudget + RelayEnvelope.buckets.last! else {
                // Unoffered, repeated, or too much at once: an honest phone never asks like that.
                throw LinkFailure.protocolViolation
            }
            links[token]?.relay.offerPending = false
            links[token]?.relay.served.formUnion(ids)
            var changed = false
            for id in ids {
                guard let bytes = relay.envelope(withID: id) else { continue }
                try send(.relayEnvelope(bytes), to: token)
                relay.recordHandOut(id, to: peer)
                changed = true
                relayActivity(.handedOver(envelope: Self.short(id), to: peer))
            }
            if !ids.isEmpty { try send(.relayDone, to: token) }
            if changed {
                markRelayDirty(keys: true, carry: true)
                refreshRelayState()
            }
            scheduleRelaySync()

        case .relayEnvelope(let data):
            // Only ever in answer to our own `relayWant`; anything else is a violation.
            let id = RelayCrypto.envelopeID(data)
            guard links[token]?.relay.outstanding.remove(id) != nil else { throw LinkFailure.protocolViolation }
            receiveEnvelope(data, id: id, from: peer)

        case .relayDone:
            links[token]?.relay.outstanding.removeAll()
            try requestMore(on: token)

        case .relayReceipts(let data):
            guard let secrets = RelayLists.split(data, width: 16, max: RelayLimits.maxReceiptsPerMessage) else {
                throw LinkFailure.protocolViolation
            }
            links[token]?.relay.receiptsKnown.formUnion(secrets)
            var anyNew = false
            for secret in secrets { anyNew = applyReceipt(secret) || anyNew }
            if anyNew {
                markRelayDirty(keys: true, carry: true)
                refreshRelayState()
                scheduleRelaySync()
            }

        default:
            throw LinkFailure.protocolViolation
        }
    }

    /// Asks for the next batch of offered envelopes (at most `wantBudget` envelopes and about
    /// `wantByteBudget` bytes), if nothing is outstanding. Answers an offer with an empty want when
    /// there is nothing to ask for, so the offering phone may offer again.
    private func requestMore(on token: PeerToken) throws {
        guard var link = links[token], link.relay.outstanding.isEmpty else { return }
        var batch: [Data] = []
        var bytes = 0
        while batch.count < RelayLimits.wantBudget, let next = link.relay.peerOffered.first,
              batch.isEmpty || bytes + next.size <= RelayLimits.wantByteBudget {
            link.relay.peerOffered.removeFirst()
            guard !relay.isSeen(next.id), !relay.isHeld(next.id) else { continue }
            batch.append(next.id)
            bytes += next.size
        }
        guard !batch.isEmpty || link.relay.owesWant else { return }
        link.relay.owesWant = false
        link.relay.outstanding = Set(batch)
        links[token] = link
        try send(.relayWant(batch.reduce(Data(), +)), to: token)
    }

    /// Enforces the per-link allowance for relay control messages. It is separate from (and larger
    /// than) the text allowance; with exchanges spaced by `relayMinExchangeInterval` an honest phone
    /// sends at most a few per second on each link, well under it.
    private func chargeRelayMessage(on token: PeerToken) throws {
        guard var link = links[token] else { return }
        let now = ContinuousClock.now
        let elapsed = now - link.relay.budgetUpdated
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        link.relay.budget = min(configuration.relayIncomingBurst, link.relay.budget + seconds * configuration.relayIncomingRate)
        link.relay.budgetUpdated = now
        guard link.relay.budget >= 1 else { throw LinkFailure.protocolViolation }
        link.relay.budget -= 1
        links[token] = link
    }

    /// An envelope arrived from a contact's phone. It may be for this phone, or for someone else.
    private func receiveEnvelope(_ data: Data, id: Data, from depositor: ContactID) {
        let now = configuration.now()
        let short = Self.short(id)
        defer { markRelayDirty(carry: true) }
        guard let envelope = RelayEnvelope(parsing: data) else {
            relay.markSeen(id, receiptHash: Data(count: 16), now: now)
            relayActivity(.refused(envelope: short, reason: "malformed"))
            return
        }
        guard envelope.isFresh(at: now) else {
            relay.markSeen(id, receiptHash: envelope.receiptHash, now: now)
            relayActivity(.refused(envelope: short, reason: "expired"))
            return
        }
        guard relay.markSeen(id, receiptHash: envelope.receiptHash, now: now) else {
            relayActivity(.refused(envelope: short, reason: "already seen"))
            return
        }
        switch relay.open(envelope, now: now) {
        case .opened(let sender, let inner, let receiptSecret):
            markRelayDirty(keys: true)
            guard let contact = contact(sender), !contact.isBlocked else {
                relayActivity(.refused(envelope: short, reason: "blocked"))
                return
            }
            relayActivity(.opened(envelope: short, from: sender))
            if knownMessageIDs[sender]?.contains(inner.messageID) == true {
                // Already here (directly, or an earlier copy): confirm again so the sender converges.
                releaseReceipt(receiptSecret)
                return
            }
            let message = Message(id: inner.messageID, direction: .incoming, text: inner.text,
                                  timestamp: now, status: .delivered, relayed: true)
            storeRelayed(message, from: sender, receiptSecret: receiptSecret)

        case .rejected(let reason):
            markRelayDirty(keys: true)
            relayActivity(.refused(envelope: short, reason: reason))

        case .notMine:
            guard carryMode != .off, relay.carry(envelope, from: depositor) else {
                relayActivity(.refused(envelope: short, reason: "not kept (full, over this contact's share, or already delivered)"))
                return
            }
            relayActivity(.carried(envelope: short, bytes: data.count))
            refreshRelayState()
            scheduleRelaySync()
        }
    }

    /// Stores a message that arrived by relay. The receipt is released only once it is safely
    /// saved, exactly like a direct receipt: "Delivered" on the sender's phone means stored here.
    private func storeRelayed(_ message: Message, from id: ContactID, receiptSecret: Data) {
        conversations[id, default: Conversation()].messages.append(message)
        knownMessageIDs[id, default: []].insert(message.id)
        trimHistory(id)
        if activeConversation != id { conversations[id]?.unreadCount += 1 }
        onEvent?(.messageReceived(id, message))
        guard let conversation = conversations[id] else { return }
        persistence.save(conversation: conversation, for: id) { [weak self] stored in
            guard stored else { return }
            Self.onMain { self?.releaseReceipt(receiptSecret) }
        }
    }

    /// Applies one receipt from a peer. Returns true if it was new and is now kept.
    private func applyReceipt(_ secret: Data) -> Bool {
        let effect = relay.applyReceipt(secret, now: configuration.now())
        if effect.deletedCarried || !effect.delivered.isEmpty {
            relayActivity(.receiptReceived(deletedCarried: effect.deletedCarried, delivered: !effect.delivered.isEmpty))
        }
        for entry in effect.delivered { markRelayDelivered(entry.messageID, in: entry.contact) }
        return effect.isNew
    }

    private func markRelayDelivered(_ messageID: UUID, in id: ContactID) {
        guard contact(id)?.isBlocked == false,
              let index = conversations[id]?.messages.lastIndex(where: { $0.id == messageID }),
              let message = conversations[id]?.messages[index],
              message.direction == .outgoing, message.status != .delivered else { return }
        conversations[id]?.messages[index].status = .delivered
        conversations[id]?.messages[index].relayed = true
        persist(id)
    }

    /// Keeps a receipt this phone made and passes it to every relay link.
    func releaseReceipt(_ secret: Data) {
        guard carryMode != .off else { return }
        let effect = relay.releaseOwnReceipt(secret, now: configuration.now())
        for entry in effect.delivered { markRelayDelivered(entry.messageID, in: entry.contact) }
        relayActivity(.receiptReleased)
        markRelayDirty(keys: !effect.delivered.isEmpty, carry: true)
        refreshRelayState()
        scheduleRelaySync()
    }

    // MARK: Housekeeping

    /// Drops expired envelopes every few minutes while Earshot is on.
    func scheduleRelayHousekeeping() {
        after(configuration.relayHousekeepingInterval) { messenger in
            messenger.relayHousekeeping()
            messenger.scheduleRelayHousekeeping()
        }
    }

    func relayHousekeeping() {
        let expired = relay.purge(now: configuration.now())
        guard expired > 0 else { return }
        saveRelayKeys()
        saveRelayCarry()
        relayActivity(.expired(count: expired))
        refreshRelayState()
    }

    /// Recomputes the relay facts the interface reads.
    func refreshRelayState() {
        let contactsWithKeys = carryMode == .off ? [] : Set(contacts.filter {
            !$0.isBlocked && relay.hasConfirmedGeneration($0.id)
        }.map(\.id))
        if contactsWithKeys != relayContacts { relayContacts = contactsWithKeys }
        let carriers = Set(links.values.compactMap { $0.relay.active ? $0.contactID : nil })
        if carriers != relayCarriersInRange { relayCarriersInRange = carriers }
        var handoffs: [UUID: Int] = [:]
        for entry in relay.keys.outbox where !entry.expired { handoffs[entry.messageID] = entry.carriers.count }
        if handoffs != relayHandoffs { relayHandoffs = handoffs }
        if relay.carried.count != carriedMailCount { carriedMailCount = relay.carried.count }
        let bytes = relay.carriedBytes
        if bytes != carriedMailBytes { carriedMailBytes = bytes }
    }

    // MARK: Saving

    /// Saves the relay keys now. Used where the order matters (write-ahead after sealing, a new
    /// generation before `relaySync`) and for rare changes. Everything else goes through `markRelayDirty`.
    func saveRelayKeys(_ then: (@MainActor (Messenger, Bool) -> Void)? = nil) {
        relayKeysDirty = false
        guard !relaySavesSuspended else {
            if let then { then(self, false) }
            return
        }
        let data = relay.encodedKeys()
        guard let then else {
            persistence.save(blob: data, named: Self.relayKeysBlob, completion: nil)
            return
        }
        persistence.save(blob: data, named: Self.relayKeysBlob) { [weak self] stored in
            Self.onMain { if let self { then(self, stored) } }
        }
    }

    func saveRelayCarry() {
        relayCarryDirty = false
        guard !relaySavesSuspended else { return }
        persistence.save(blob: relay.encodedCarry(), named: Self.relayCarryBlob, completion: nil)
    }

    /// Frequent relay changes (each envelope, receipt or hand-over) are saved together at most once
    /// per `relaySaveDelay`, instead of encoding the whole store for every packet. Losing the last
    /// moment of them in a crash is harmless: carried mail is best effort, a message opened twice is
    /// recognised by its ID, and sealing never relies on this path.
    func markRelayDirty(keys: Bool = false, carry: Bool = false) {
        relayKeysDirty = relayKeysDirty || keys
        relayCarryDirty = relayCarryDirty || carry
        guard !relaySaveScheduled, relayKeysDirty || relayCarryDirty else { return }
        relaySaveScheduled = true
        after(configuration.relaySaveDelay) { messenger in
            messenger.relaySaveScheduled = false
            messenger.flushRelaySaves()
        }
    }

    /// Writes any pending relay changes now (also when going off the air).
    func flushRelaySaves() {
        if !relayUnpersisted.isEmpty {
            writeAheadNow()
        } else if relayKeysDirty {
            saveRelayKeys()
        }
        if relayCarryDirty { saveRelayCarry() }
    }

    // MARK: Diagnostics

    private static let relayLog = Logger(subsystem: "app.earshot", category: "relay")

    func relayActivity(_ activity: RelayActivity) {
        // Logged without contact IDs (and redacted by default); the full event goes to the callback.
        Self.relayLog.debug("\(activity.logLine, privacy: .private)")
        onRelayActivity?(activity)
    }

    static func short(_ id: Data) -> String { id.prefix(4).map { String(format: "%02x", $0) }.joined() }

    /// Runs on the main actor, now if already there (persistence completions may come from any thread).
    nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}
