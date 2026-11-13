import CryptoKit
import Foundation
import Testing
@testable import EarshotKit

/// A clock tests can move forward (relay expiry is measured in hours and days).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

extension Messenger.Configuration {
    static func relay(_ clock: TestClock) -> Messenger.Configuration {
        var c = Messenger.Configuration.fast
        c.now = { clock.now }
        c.relaySyncDelay = .milliseconds(5)
        c.relayMinExchangeInterval = .milliseconds(20)
        c.relaySaveDelay = .milliseconds(20)
        return c
    }
}

// MARK: - Envelope and key schedule (no Messenger)

/// Two phones' relay state for one pair, set up as if they had just met directly.
private struct Pair {
    let ashaKey = Identity().publicKey
    let benKey = Identity().publicKey
    var asha = RelayState()
    var ben = RelayState()
    let ashaSeesBen: ContactID
    let benSeesAsha: ContactID
    let now: Date

    init(now: Date = Date(), root: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.now = now
        ashaSeesBen = ContactID(identityKey: benKey)
        benSeesAsha = ContactID(identityKey: ashaKey)
        let a = asha.installGeneration(contact: ashaSeesBen, root: root, ownIdentityKey: ashaKey, peerIdentityKey: benKey, now: now)
        let b = ben.installGeneration(contact: benSeesAsha, root: root, ownIdentityKey: benKey, peerIdentityKey: ashaKey, now: now)
        asha.confirm(contact: ashaSeesBen, send: a.send)
        ben.confirm(contact: benSeesAsha, send: b.send)
    }

    mutating func seal(_ text: String) throws -> RelayEnvelope {
        let sealed = asha.seal(text: text, messageID: UUID(), sentAt: now, to: ashaSeesBen, now: now)
        let entry = try #require(sealed)
        return try #require(RelayEnvelope(parsing: entry.envelope))
    }
}

@Suite struct RelayEnvelopeTests {
    @Test func envelopesComeInThreeFixedSizesWithTheDocumentedHeader() throws {
        var pair = Pair()
        let short = try pair.seal("North gate at 6")
        let medium = try pair.seal(String(repeating: "a", count: 1000))
        // 2,000 four-byte characters: the longest message Earshot allows still fits the largest size.
        let long = try pair.seal(String(repeating: "😀", count: 2000))
        #expect(short.bytes.count == 512)
        #expect(medium.bytes.count == 2048)
        #expect(long.bytes.count == 8192)
        #expect(short.bytes.first == 1)
        let hours = short.expiresHour
        #expect(hours % 6 == 0)
        let ahead = TimeInterval(hours) * 3600 - pair.now.timeIntervalSince1970
        #expect(ahead > 41 * 3600 && ahead <= 48 * 3600)
        #expect(short.isFresh(at: pair.now))
    }

    @Test func everyHeaderAndBodyByteIsProtected() throws {
        var pair = Pair()
        let sealed = pair.asha.seal(text: "hello", messageID: UUID(), sentAt: pair.now, to: pair.ashaSeesBen, now: pair.now)
        let entry = try #require(sealed)
        let original = try #require(RelayEnvelope(parsing: entry.envelope))
        // Recover the message key the way the recipient would, to test the AEAD alone.
        let chain = try #require(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.first)
        let key = RelayCrypto.step(chain.key).messageKey
        #expect((try? original.open(with: key)) != nil)
        for offset in [0, 1, 16, 17, 32, 33, 36, 37, 48, 49, 300, 511] {
            var bytes = [UInt8](original.bytes)
            bytes[offset] ^= 0x01
            if let changed = RelayEnvelope(parsing: Data(bytes)) {
                #expect((try? changed.open(with: key)) == nil, "byte \(offset) was not protected")
            }
        }
    }

    @Test func innerPlaintextIsStrict() throws {
        let inner = RelayInner(messageID: UUID(), sentAt: 1_700_000_000_000, text: "hi")
        let plain = try #require(inner.encoded(bucket: 512))
        #expect(plain.count == 512 - 65)
        #expect(try RelayInner.decode(plain) == inner)
        var padding = [UInt8](plain); padding[plain.count - 1] = 1
        #expect(throws: (any Error).self) { try RelayInner.decode(Data(padding)) }
        var type = [UInt8](plain); type[0] = 2
        #expect(throws: (any Error).self) { try RelayInner.decode(Data(type)) }
        var length = [UInt8](plain); length[25] = 0xFF
        #expect(throws: (any Error).self) { try RelayInner.decode(Data(length)) }
        #expect(RelayInner(messageID: UUID(), sentAt: 0, text: String(repeating: "x", count: 8101)).encoded(bucket: 8192) == nil)
    }

    @Test func malformedOuterShapesAreRefusedBeforeAnythingElse() {
        #expect(RelayEnvelope(parsing: Data(count: 511)) == nil)
        #expect(RelayEnvelope(parsing: Data(count: 1024)) == nil)
        #expect(RelayEnvelope(parsing: Data(repeating: 2, count: 512)) == nil)
        #expect(RelayEnvelope(parsing: Data([1]) + Data(count: 511)) != nil)
    }

    @Test func relayPayloadsFitTheSmallestFrameLimit() throws {
        // The largest frame any relay payload can make, sealed as on a real link.
        var channel = SecureChannel(sendKey: SymmetricKey(size: .bits256), receiveKey: SymmetricKey(size: .bits256))
        let payloads: [Payload] = [
            .relayEnvelope(Data(count: 8192)),
            .relayOffer(Data(count: RelayLimits.maxOfferEntries * RelayLists.offerEntryLength)),
            .relayWant(Data(count: RelayLimits.maxOfferEntries * 8)),
            .relayReceipts(Data(count: RelayLimits.maxReceiptsPerMessage * 16)),
            .relaySync(Data(count: 8)), .relayDone,
        ]
        for payload in payloads {
            let frame = Frame.sealed(try channel.seal(try payload.encoded())).encoded()
            #expect(frame.count < 16 * 1024, "\(payload) makes a \(frame.count)-byte frame")
            #expect(frame.count <= Frame.maxSize && frame.count + 1 <= BluetoothWire.maxFrameLength)
            #expect(try Payload.decode(try payload.encoded()) == payload)
        }
    }
}

@Suite struct RelayStateTests {
    @Test func outOfOrderLostAndReplayedMessages() throws {
        var pair = Pair()
        let envelopes = try (0..<5).map { try pair.seal("message \($0)") }
        var opened: [String] = []
        for index in [4, 2, 0, 1, 3] {
            guard case .opened(let from, let inner, _) = pair.ben.open(envelopes[index], now: pair.now) else {
                Issue.record("message \(index) did not open"); continue
            }
            #expect(from == pair.benSeesAsha)
            opened.append(inner.text)
        }
        #expect(opened == ["message 4", "message 2", "message 0", "message 1", "message 3"])
        // Every slot is used up: replays are not even recognised.
        for envelope in envelopes {
            let result = pair.ben.open(envelope, now: pair.now)
            #expect(result == .notMine)
        }
        let chain = try #require(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.first)
        #expect(chain.base == 5)
        #expect(chain.skipped.isEmpty)
    }

    @Test func junkCopyingARealTagDoesNotUseUpTheSlot() throws {
        var pair = Pair()
        let real = try pair.seal("the real one")
        var bytes = [UInt8](real.bytes)
        for i in 49..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let junk = try #require(RelayEnvelope(parsing: Data(bytes)))
        #expect(junk.tag == real.tag)
        #expect(junk.id != real.id)
        let junkResult = pair.ben.open(junk, now: pair.now)
        #expect(junkResult == .rejected("did not decrypt"))
        guard case .opened(_, let inner, _) = pair.ben.open(real, now: pair.now) else {
            Issue.record("the genuine envelope must still open"); return
        }
        #expect(inner.text == "the real one")
    }

    @Test func senderNeverSealsBeyondWhatTheRecipientCanRecognise() throws {
        var pair = Pair()
        var sealed = 0
        while pair.asha.seal(text: "x", messageID: UUID(), sentAt: pair.now, to: pair.ashaSeesBen, now: pair.now) != nil { sealed += 1 }
        // The per-contact cap (200) stops it before the lookahead (256) would.
        #expect(sealed == RelayLimits.maxOutstandingPerContact)
        // Even with the cap lifted (old copies expired), the lookahead still holds.
        for index in pair.asha.keys.outbox.indices { pair.asha.keys.outbox[index].expired = true }
        while pair.asha.seal(text: "x", messageID: UUID(), sentAt: pair.now, to: pair.ashaSeesBen, now: pair.now) != nil { sealed += 1 }
        #expect(sealed == RelayLimits.lookahead)
        // A receipt for index 9 lets ten more through.
        let tenth = pair.asha.keys.outbox[9]
        _ = pair.asha.applyReceipt(tenth.receiptSecret, now: pair.now)
        var more = 0
        for index in pair.asha.keys.outbox.indices { pair.asha.keys.outbox[index].expired = true }
        while pair.asha.seal(text: "x", messageID: UUID(), sentAt: pair.now, to: pair.ashaSeesBen, now: pair.now) != nil { more += 1 }
        #expect(more == 10)
    }

    @Test func aTextTooLargeForTheBiggestEnvelopeIsNotSealedAndUsesNoIndex() throws {
        var pair = Pair()
        let huge = String(repeating: "👨‍👩‍👧‍👦", count: 400) // 25 bytes each in UTF-8
        let sealed = pair.asha.seal(text: huge, messageID: UUID(), sentAt: pair.now, to: pair.ashaSeesBen, now: pair.now)
        #expect(sealed == nil)
        #expect(pair.asha.keys.pairs[pair.ashaSeesBen.rawValue]?.send?.index == 0)
    }

    @Test func olderGenerationsKeepWorkingForAWeekThenRetire() throws {
        var pair = Pair()
        let old = try pair.seal("sealed under the first generation")
        let later = pair.now.addingTimeInterval(3600)
        let newer = pair.ben.installGeneration(contact: pair.benSeesAsha, root: SymmetricKey(size: .bits256),
                                               ownIdentityKey: pair.benKey, peerIdentityKey: pair.ashaKey, now: later)
        #expect(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.count == 2)
        guard case .opened = pair.ben.open(old, now: later) else { Issue.record("old generation must still open"); return }
        // Not confirmed by Asha: the old generation stays however long it takes (she may still use it).
        _ = pair.ben.purge(now: later.addingTimeInterval(30 * 86_400))
        #expect(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.count == 2)
        // Asha confirms the newer one: a week later the old one retires.
        pair.ben.markPeerConfirmed(contact: pair.benSeesAsha.rawValue, generation: newer.generation,
                                   now: later.addingTimeInterval(30 * 86_400))
        _ = pair.ben.purge(now: later.addingTimeInterval(36 * 86_400))
        #expect(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.count == 2, "within the week")
        _ = pair.ben.purge(now: later.addingTimeInterval(38 * 86_400))
        #expect(pair.ben.keys.pairs[pair.benSeesAsha.rawValue]?.receive.map(\.generation) == [newer.generation])
    }

    @Test func stateSurvivesSavingAndLoading() throws {
        var pair = Pair()
        let first = try pair.seal("one")
        let second = try pair.seal("two")
        _ = pair.ben.open(second, now: pair.now) // index 0 becomes a skipped key
        pair.ben.markSeen(second.id, receiptHash: second.receiptHash, now: pair.now)
        let other = try pair.seal("someone else's")
        let carried = pair.ben.carry(other)
        #expect(carried)
        let reloaded = RelayState(keysData: pair.ben.encodedKeys(), carryData: pair.ben.encodedCarry())
        #expect(reloaded.keys == pair.ben.keys)
        #expect(reloaded.carried == pair.ben.carried)
        #expect(reloaded.isSeen(second.id))
        var copy = reloaded
        guard case .opened(_, let inner, _) = copy.open(first, now: pair.now) else {
            Issue.record("a skipped message must open after a restart"); return
        }
        #expect(inner.text == "one")
        // A missing store starts empty; an unreadable one starts empty AND with relaying off (fail closed).
        #expect(RelayState(keysData: nil, carryData: nil).keys == RelayKeys())
        let unreadable = RelayState(keysData: Data("garbage".utf8), carryData: Data([1, 2, 3]))
        #expect(unreadable.keys.carryMode == .off)
        #expect(unreadable.keysUnreadable)
        #expect(unreadable.carried.isEmpty)
    }

    @Test func theSeenListForgetsTheOldestWhenFull() {
        var state = RelayState()
        let now = Date()
        for i in 0...RelayLimits.maxSeen {
            var id = Data(count: 8)
            withUnsafeBytes(of: UInt64(i).bigEndian) { id = Data($0) }
            state.markSeen(id, receiptHash: Data(count: 16), now: now)
        }
        #expect(state.seen.count == RelayLimits.maxSeen)
        #expect(!state.isSeen(Data(count: 8)), "the first entry is forgotten: a duplicate may be taken again, nothing new is refused")
    }

    @Test func receiptsDeleteCarriedCopiesAndUnknownReceiptsAreIgnored() throws {
        var pair = Pair()
        let envelope = try pair.seal("for Ben")
        var carrier = RelayState()
        let carried = carrier.carry(envelope)
        #expect(carried)
        let unknown = carrier.applyReceipt(Data(repeating: 7, count: 16), now: pair.now)
        #expect(unknown == RelayState.ReceiptEffect())
        #expect(carrier.receipts.isEmpty)
        guard case .opened(_, _, let secret) = pair.ben.open(envelope, now: pair.now) else { Issue.record("did not open"); return }
        let effect = carrier.applyReceipt(secret, now: pair.now)
        #expect(effect.deletedCarried && effect.known && effect.isNew)
        #expect(carrier.carried.isEmpty)
        // Once confirmed, the same envelope is never carried again.
        let again = carrier.carry(envelope)
        #expect(!again)
        // The sender learns it was delivered.
        let sender = pair.asha.applyReceipt(secret, now: pair.now)
        #expect(sender.delivered.count == 1)
        #expect(pair.asha.keys.outbox.isEmpty)
    }

    @Test func expiredMailIsDropped() throws {
        var pair = Pair()
        let envelope = try pair.seal("short-lived")
        var carrier = RelayState()
        let carried = carrier.carry(envelope)
        #expect(carried)
        let early = carrier.purge(now: pair.now.addingTimeInterval(41 * 3600))
        #expect(early == 0)
        let late = carrier.purge(now: pair.now.addingTimeInterval(49 * 3600))
        #expect(late == 1)
        #expect(carrier.carried.isEmpty)
        let own = pair.asha.purge(now: pair.now.addingTimeInterval(49 * 3600))
        #expect(own == 1)
        #expect(pair.asha.offerable(now: pair.now.addingTimeInterval(49 * 3600)).isEmpty)
        #expect(!envelope.isFresh(at: pair.now.addingTimeInterval(49 * 3600)))
    }

    @Test func carryingStopsAtTheQuota() throws {
        var pair = Pair()
        var carrier = RelayState()
        let big = String(repeating: "b", count: 7000)
        var stored = 0
        for _ in 0..<300 {
            for index in pair.asha.keys.outbox.indices { pair.asha.keys.outbox[index].expired = true }
            if pair.asha.keys.pairs[pair.ashaSeesBen.rawValue]?.send?.index == UInt32(RelayLimits.lookahead) { break }
            if carrier.carry(try pair.seal(big)) { stored += 1 }
        }
        #expect(carrier.carriedBytes <= RelayLimits.carryMaxBytes)
        #expect(stored == RelayLimits.carryMaxBytes / 8192)
    }
}

// MARK: - Three phones over the loopback radio

@MainActor
private struct Trio {
    let hub: LoopbackHub
    let clock: TestClock
    let a: Phone, b: Phone, c: Phone
    /// How each phone names the others.
    let aSeesB: ContactID, bSeesA: ContactID, aSeesC: ContactID, cSeesA: ContactID, cSeesB: ContactID, bSeesC: ContactID
    var activity: ActivityLog

    /// A and B are contacts who confirmed relay keys, then moved apart. C is linked to both
    /// (C–B only when `linkCToB`).
    static func make(linkCToB: Bool = true, bConfiguration: ((inout Messenger.Configuration) -> Void)? = nil) async throws -> Trio {
        let hub = LoopbackHub()
        let clock = TestClock()
        var bConfig = Messenger.Configuration.relay(clock)
        bConfiguration?(&bConfig)
        let a = makePhone(hub, "Asha", configuration: .relay(clock))
        let b = makePhone(hub, "Ben", configuration: bConfig)
        let c = makePhone(hub, "Chidi", configuration: .relay(clock))
        let log = ActivityLog()
        for (name, phone) in [("A", a), ("B", b), ("C", c)] {
            phone.messenger.onRelayActivity = { log.events.append((name, $0)) }
        }
        let ab = try befriend(a, b)
        if bConfig.announcesRelay {
            await waitUntil("A and B confirmed relay keys") {
                a.messenger.canRelay(to: ab.aSeesB) && b.messenger.canRelay(to: ab.bSeesA)
            }
        }
        let ac = try befriend(a, c)
        let cb = try befriend(c, b)
        hub.setInRange(false, a.transport, b.transport)
        if !linkCToB { hub.setInRange(false, c.transport, b.transport) }
        await waitUntil("A and B apart") {
            a.messenger.linkState(for: ab.aSeesB) == .outOfRange && b.messenger.linkState(for: ab.bSeesA) == .outOfRange
        }
        return Trio(hub: hub, clock: clock, a: a, b: b, c: c, aSeesB: ab.aSeesB, bSeesA: ab.bSeesA,
                    aSeesC: ac.aSeesB, cSeesA: ac.bSeesA, cSeesB: cb.aSeesB, bSeesC: cb.bSeesA, activity: log)
    }
}

@MainActor
final class ActivityLog {
    var events: [(phone: String, activity: RelayActivity)] = []
    func count(_ phone: String, _ matches: (RelayActivity) -> Bool) -> Int {
        events.filter { $0.phone == phone && matches($0.activity) }.count
    }
}

@MainActor
@Suite struct RelayDeliveryTests {
    @Test func aMessageTravelsThroughAFriendAndTheReceiptComesBack() async throws {
        let t = try await Trio.make()
        let cMessagesBefore = t.c.messenger.conversations.values.map(\.messages.count).reduce(0, +)
        var cEvents = 0
        t.c.messenger.onEvent = { if case .messageReceived = $0 { cEvents += 1 } }

        let sent = try #require(t.a.messenger.send("North gate at 6", to: t.aSeesB))
        await waitUntil("Ben has the message") { t.b.messenger.messages(for: t.bSeesA).contains { $0.id == sent.id } }
        let received = try #require(t.b.messenger.messages(for: t.bSeesA).first { $0.id == sent.id })
        #expect(received.text == "North gate at 6")
        #expect(received.relayed == true)
        #expect(received.direction == .incoming)

        await waitUntil("Asha sees Delivered") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.relayed == true)
        await waitUntil("Chidi's copy is deleted") { t.c.messenger.carriedMailCount == 0 }
        #expect(t.a.messenger.relayHandoffs.isEmpty)

        // Chidi's phone never showed anything about it.
        #expect(cEvents == 0)
        #expect(t.c.messenger.conversations.values.map(\.messages.count).reduce(0, +) == cMessagesBefore)
        #expect(t.activity.count("C") { if case .opened = $0 { true } else { false } } == 0)
        #expect(t.activity.count("C") { if case .carried = $0 { true } else { false } } == 1)
        // Every link stayed up: nobody broke a rule.
        #expect(t.a.messenger.linkState(for: t.aSeesC) == .connected)
        #expect(t.b.messenger.linkState(for: t.bSeesC) == .connected)
    }

    @Test func mailWaitsWithTheCarrierUntilItMeetsTheRecipient() async throws {
        let t = try await Trio.make(linkCToB: false)
        let sent = try #require(t.a.messenger.send("See you at the gate", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        #expect(t.a.messenger.relayHandoffs[sent.id] == 1)
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.status == .waiting)

        t.clock.advance(hours: 3)
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben has it three hours later") { t.b.messenger.messages(for: t.bSeesA).contains { $0.id == sent.id } }
        await waitUntil("Asha sees Delivered") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
    }

    @Test func expiredMailIsDroppedAndTheMessageStillArrivesDirectly() async throws {
        let t = try await Trio.make(linkCToB: false)
        let sent = try #require(t.a.messenger.send("Still there?", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }

        t.clock.advance(hours: 49)
        t.c.messenger.relayHousekeeping()
        t.a.messenger.relayHousekeeping()
        #expect(t.c.messenger.carriedMailCount == 0)
        #expect(t.a.messenger.relayHandoffs.isEmpty)
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.status == .waiting)

        // Chidi meets Ben: nothing to hand over any more.
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("C and B linked") { t.c.messenger.linkState(for: t.cSeesB) == .connected }
        await pause(60)
        #expect(t.b.messenger.messages(for: t.bSeesA).isEmpty)

        // Asha meets Ben: delivered directly, once.
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("delivered directly") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.relayed == nil)
        #expect(t.b.messenger.messages(for: t.bSeesA).map(\.id) == [sent.id])
    }

    @Test func withoutConfirmedKeysNothingIsSealed() async throws {
        // Ben runs a build without relaying (or switched it off): no keys were ever confirmed.
        let t = try await Trio.make { $0.announcesRelay = false }
        #expect(!t.a.messenger.canRelay(to: t.aSeesB))
        let sent = try #require(t.a.messenger.send("Waits for range", to: t.aSeesB))
        await pause(80)
        #expect(t.a.messenger.relayHandoffs[sent.id] == nil)
        #expect(t.c.messenger.carriedMailCount == 0)
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.status == .waiting)
        // Ben's link to Chidi carried no relay payload: any would have closed it.
        #expect(t.b.messenger.linkState(for: t.bSeesC) == .connected)
        #expect(!t.c.messenger.relayCarriersInRange.contains(t.cSeesB))
        // And it still arrives when they meet.
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("delivered directly") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
    }

    @Test func receivedByRelayThenMeetingDirectlyGivesNoDuplicate() async throws {
        let t = try await Trio.make(linkCToB: false)
        let sent = try #require(t.a.messenger.send("Only once please", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        // Asha walks away from Chidi before any receipt can come back.
        t.hub.setInRange(false, t.a.transport, t.c.transport)
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben has it") { t.b.messenger.messages(for: t.bSeesA).contains { $0.id == sent.id } }
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.status == .waiting)

        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("Asha sees Delivered") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
        await pause(60)
        #expect(t.b.messenger.messages(for: t.bSeesA).filter { $0.id == sent.id }.count == 1)
        #expect(t.a.messenger.messages(for: t.aSeesB).filter { $0.id == sent.id }.count == 1)
        #expect(t.a.messenger.relayHandoffs.isEmpty)
    }

    @Test func directDeliveryClearsTheCopiesFriendsCarry() async throws {
        let t = try await Trio.make(linkCToB: false)
        _ = try #require(t.a.messenger.send("Going direct", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("delivered directly") { t.a.messenger.messages(for: t.aSeesB).first?.status == .delivered }
        // Asha released the receipt herself; Chidi deletes the copy without ever meeting Ben.
        await waitUntil("Chidi's copy is gone") { t.c.messenger.carriedMailCount == 0 }
    }

    @Test func requestsDoNotDependOnWhoTheMailIsFor() async throws {
        // Chidi carries three envelopes: one for Ben and two for people Ben does not know.
        let t = try await Trio.make(linkCToB: false)
        _ = try #require(t.a.messenger.send("for Ben", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        var stranger = Pair()
        for text in ["for someone else 1", "for someone else 2"] {
            let envelope = try stranger.seal(text)
            let carried = t.c.messenger.relay.carry(envelope)
            #expect(carried)
        }
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben has the message") { !t.b.messenger.messages(for: t.bSeesA).isEmpty }
        await waitUntil("Ben carries the other two") { t.b.messenger.carriedMailCount == 2 }
        #expect(t.activity.count("C") { if case .handedOver(_, let to) = $0 { to == t.cSeesB } else { false } } == 3)
    }
}

@MainActor
@Suite struct RelayHostileTests {
    /// Chidi's phone misbehaves: it changes what it carries before handing it to Ben.
    @Test func tamperedJunkAndReplayedEnvelopesAreRefusedAndTheRealOneStillOpens() async throws {
        let t = try await Trio.make(linkCToB: false)
        let sent = try #require(t.a.messenger.send("the genuine message", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        let genuine = try #require(t.c.messenger.relay.carried.first?.envelope)

        // Junk with the same tag, a copy with one header byte flipped, both offered first.
        var junk = [UInt8](genuine.bytes)
        for i in 49..<junk.count { junk[i] = UInt8.random(in: 0...255) }
        var flipped = [UInt8](genuine.bytes)
        flipped[40] ^= 0x80 // inside the nonce
        let fakes = [Data(junk), Data(flipped)].compactMap { RelayEnvelope(parsing: $0) }
        #expect(fakes.count == 2)
        t.c.messenger.relay.carried = fakes.map { CarriedEnvelope(envelope: $0, id: $0.id) } + t.c.messenger.relay.carried

        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben has the genuine message") { t.b.messenger.messages(for: t.bSeesA).contains { $0.id == sent.id } }
        #expect(t.b.messenger.messages(for: t.bSeesA).count == 1)
        // Offers are shuffled, so the fakes may come before or after the genuine one. Before: they fail
        // to decrypt and leave the slot free. After: the tag is used up and the known receipt means
        // Ben's phone will not carry them either. Either way both are refused and nothing else changes.
        #expect(t.activity.count("B") { if case .refused = $0 { true } else { false } } == 2)
        #expect(t.b.messenger.carriedMailCount == 0)
        #expect(t.b.messenger.linkState(for: t.bSeesC) == .connected)

        // Chidi replays the genuine envelope later. Ben's phone has seen it: it does not even ask.
        await waitUntil("receipt reached Chidi") { t.c.messenger.relay.carried.allSatisfy { $0.id != genuine.id } }
        t.c.messenger.relay.carried.append(CarriedEnvelope(envelope: genuine, id: genuine.id))
        t.hub.dropConnection(t.c.transport, t.b.transport)
        await waitUntil("C and B linked again") { t.c.messenger.linkState(for: t.cSeesB) == .connected }
        await pause(60)
        #expect(t.b.messenger.messages(for: t.bSeesA).count == 1)

        // Even if Ben's phone had forgotten it (seen list overflow), the used-up tag makes it a stranger's
        // envelope, and the known receipt stops Ben from carrying it on.
        let effect = t.b.messenger.relay.open(genuine, now: t.clock.now)
        #expect(effect == .notMine)
        let carried = t.b.messenger.relay.carry(genuine)
        #expect(!carried)
    }

    @Test func unsolicitedOrUnofferedRelayPayloadsCloseTheLink() async throws {
        let t = try await Trio.make()
        let token = try #require(t.c.messenger.links.first { $0.value.contactID == t.cSeesB }?.key)
        // An envelope nobody asked for.
        try t.c.messenger.send(.relayEnvelope(Data([1]) + Data(count: 511)), to: token)
        await waitUntil("Ben closed the link") { t.b.messenger.linkState(for: t.bSeesC) != .connected }
    }

    @Test func aWantForSomethingNeverOfferedClosesTheLink() async throws {
        let t = try await Trio.make()
        let token = try #require(t.b.messenger.links.first { $0.value.contactID == t.bSeesC }?.key)
        try t.b.messenger.send(.relayWant(Data(repeating: 9, count: 8)), to: token)
        await waitUntil("Chidi closed the link") { t.c.messenger.linkState(for: t.cSeesB) != .connected }
    }

    @Test func aRelayPayloadToAPhoneThatDidNotAgreeClosesTheLink() async throws {
        let t = try await Trio.make { $0.announcesRelay = false }
        let token = try #require(t.c.messenger.links.first { $0.value.contactID == t.cSeesB }?.key)
        try t.c.messenger.send(.relayOffer(Data(count: 9)), to: token)
        await waitUntil("Ben closed the link") { t.b.messenger.linkState(for: t.bSeesC) != .connected }
    }
}

@MainActor
@Suite struct RelayPrivacyTests {
    @Test func envelopesCarryNothingThatNamesEitherPerson() async throws {
        let t = try await Trio.make(linkCToB: false)
        _ = t.a.messenger.send("first", to: t.aSeesB)
        _ = t.a.messenger.send("second", to: t.aSeesB)
        await waitUntil("Chidi carries both") { t.c.messenger.carriedMailCount == 2 }
        let envelopes = t.c.messenger.relay.carried.map(\.envelope.bytes)
        // Stop here if the wait above failed: indexing an empty list would crash the whole test run.
        try #require(envelopes.count == 2)
        let secrets: [Data] = [t.a.messenger.identityKey, t.b.messenger.identityKey,
                               Data(t.aSeesB.rawValue.utf8), Data(t.bSeesA.rawValue.utf8),
                               Data("Asha".utf8), Data("Ben".utf8),
                               Data(t.aSeesB.rawValue.prefix(8).utf8)]
        for envelope in envelopes {
            for secret in secrets { #expect(envelope.range(of: secret) == nil) }
        }
        // Two envelopes to the same person share only the version and the coarse expiry.
        let x = [UInt8](envelopes[0]), y = [UInt8](envelopes[1])
        #expect(x[0] == y[0])
        #expect(Array(x[1..<33]) != Array(y[1..<33]))
        #expect(Array(x[37..<49]) != Array(y[37..<49]))
        #expect(zip(x[1..<17], y[1..<17]).filter { $0 == $1 }.count < 6, "tags look unrelated")
    }

    @Test func theCarrierKeepsNoRecordOfWhoHandedItTheMail() async throws {
        let t = try await Trio.make(linkCToB: false)
        _ = t.a.messenger.send("hello", to: t.aSeesB)
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        t.c.messenger.flushRelaySaves()
        let saved = try #require(t.c.persistence.load(blob: Messenger.relayCarryBlob))
        #expect(saved.range(of: Data(t.cSeesA.rawValue.utf8)) == nil)
        #expect(saved.range(of: t.a.messenger.identityKey) == nil)
        #expect(saved.range(of: t.c.messenger.identityKey) == nil)
        // The keys store names contacts only as the owners of Chidi's own relay keys. Its outbox (where
        // Chidi's own sealed messages live) is empty: the carried envelope is not recorded there.
        let keys = try #require(t.c.persistence.load(blob: Messenger.relayKeysBlob))
        let decoded = try JSONDecoder().decode(RelayKeys.self, from: keys)
        #expect(decoded.outbox.isEmpty)
        let carriedID = try #require(t.c.messenger.relay.carried.first).id
        #expect(keys.range(of: carriedID) == nil)
        #expect(keys.range(of: Data(carriedID.base64EncodedString().utf8)) == nil)
    }
}

@MainActor
@Suite struct RelaySettingsTests {
    @Test func switchingOffStopsAnnouncingAndForgetsEverything() async throws {
        let t = try await Trio.make(linkCToB: false)
        _ = t.a.messenger.send("carried", to: t.aSeesB)
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }

        t.c.messenger.setCarryMode(.off)
        #expect(t.c.messenger.carryMode == .off)
        #expect(t.c.messenger.carriedMailCount == 0)
        #expect(t.c.messenger.announcedFeatures == [Feature.photo])
        await waitUntil("C and A relinked") { t.c.messenger.linkState(for: t.cSeesA) == .connected }
        #expect(!t.a.messenger.relayCarriersInRange.contains(t.aSeesC))
        // Asha's own relay keys for Ben are not affected by Chidi's choice.
        #expect(t.a.messenger.canRelay(to: t.aSeesB))

        // Asha switching off: no sealing, no keys, the message waits for range.
        t.a.messenger.setCarryMode(.off)
        #expect(!t.a.messenger.canRelay(to: t.aSeesB))
        let waiting = try #require(t.a.messenger.send("waits", to: t.aSeesB))
        #expect(t.a.messenger.relayHandoffs[waiting.id] == nil)
        #expect(t.a.messenger.relay.keys.pairs.isEmpty)
    }

    @Test func settingAndKeysSurviveARestart() async throws {
        let hub = LoopbackHub()
        let clock = TestClock()
        let store = InMemoryPersistence(), keys = InMemoryIdentityStore()
        let a = makePhone(hub, "Asha", persistence: store, identityStore: keys, configuration: .relay(clock))
        let b = makePhone(hub, "Ben", configuration: .relay(clock))
        let ids = try befriend(a, b)
        await waitUntil("keys confirmed") { a.messenger.canRelay(to: ids.aSeesB) }
        hub.setInRange(false, a.transport, b.transport)
        _ = a.messenger.send("one", to: ids.aSeesB)
        let firstTag = try #require(a.messenger.relay.keys.outbox.first).envelope[1..<17]
        a.messenger.stop()

        let againTransport = hub.makeTransport(token: "asha-2")
        hub.setInRange(false, againTransport, b.transport)
        let again = Messenger(transport: againTransport, persistence: store, identityStore: keys,
                              configuration: .relay(clock))
        #expect(again.canRelay(to: ids.aSeesB))
        #expect(again.relayHandoffs.count == 1)
        again.start()
        _ = again.send("two", to: ids.aSeesB)
        #expect(again.relay.keys.outbox.count == 2)
        #expect(again.relay.keys.outbox.map(\.index) == [0, 1], "the chain index is never reused after a restart")
        let outbox = again.relay.keys.outbox
        try #require(outbox.count == 2)
        #expect(outbox[1].envelope[1..<17] != firstTag)

        again.setCarryMode(.off)
        let third = Messenger(transport: hub.makeTransport(token: "asha-3"), persistence: store, identityStore: keys,
                              configuration: .relay(clock))
        #expect(third.carryMode == .off)
        #expect(!third.canRelay(to: ids.aSeesB))
    }

    @Test func anOlderEarshotIsNeverSentRelayPayloadsAndKeepsWorking() async throws {
        // An Earshot from before photos and relaying: announces no features, and (like the real
        // old decoder) cannot decode any newer payload, so a single relay payload would close the link.
        let hub = LoopbackHub()
        let clock = TestClock()
        var legacy = Messenger.Configuration.relay(clock)
        legacy.legacyProtocolForTesting = true
        legacy.announcesRelay = false
        let a = makePhone(hub, "Asha", configuration: .relay(clock))
        let old = makePhone(hub, "Olu", configuration: legacy)
        let c = makePhone(hub, "Chidi", configuration: .relay(clock))
        let ao = try befriend(a, old)
        let ac = try befriend(a, c)
        _ = try befriend(c, old)
        await waitUntil("A relays with C") { a.messenger.relayCarriersInRange.contains(ac.aSeesB) }
        #expect(!a.messenger.canRelay(to: ao.aSeesB))
        #expect(!a.messenger.relayCarriersInRange.contains(ao.aSeesB))
        _ = a.messenger.send("plain text still works", to: ao.aSeesB)
        await waitUntil("delivered") { a.messenger.messages(for: ao.aSeesB).first?.status == .delivered }
        await pause(60)
        #expect(a.messenger.linkState(for: ao.aSeesB) == .connected)
        #expect(old.messenger.contacts.allSatisfy { old.messenger.linkState(for: $0.id) == .connected })
    }

    @Test func removingAContactForgetsItsRelayKeys() async throws {
        let t = try await Trio.make()
        t.a.messenger.removeContact(t.aSeesB)
        #expect(t.a.messenger.relay.keys.pairs[t.aSeesB.rawValue] == nil)
        #expect(!t.a.messenger.canRelay(to: t.aSeesB))
    }
}
