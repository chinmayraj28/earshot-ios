import CryptoKit
import Foundation
import Testing
@testable import EarshotKit

/// Two phones' relay state for one pair, as if they had just met directly.
private struct RPair {
    let aKey = Identity().publicKey, bKey = Identity().publicKey
    var a = RelayState(), b = RelayState()
    let aSeesB: ContactID, bSeesA: ContactID
    let now = Date()
    init() {
        aSeesB = ContactID(identityKey: bKey); bSeesA = ContactID(identityKey: aKey)
        let root = SymmetricKey(size: .bits256)
        let x = a.installGeneration(contact: aSeesB, root: root, ownIdentityKey: aKey, peerIdentityKey: bKey, now: now)
        _ = b.installGeneration(contact: bSeesA, root: root, ownIdentityKey: bKey, peerIdentityKey: aKey, now: now)
        a.confirm(contact: aSeesB, send: x.send)
    }
    mutating func seal(_ text: String = "x") -> RelayOutgoing? {
        a.seal(text: text, messageID: UUID(), sentAt: now, to: aSeesB, now: now)
    }
}

@MainActor
private struct Trio {
    let hub: LoopbackHub, clock: TestClock
    let a: Phone, b: Phone, c: Phone
    let aSeesB: ContactID, bSeesA: ContactID, aSeesC: ContactID, cSeesB: ContactID, bSeesC: ContactID

    static func make(linkCToB: Bool = true, syncDelay: Duration = .milliseconds(5),
                     shippingPacing: Bool = false) async throws -> Trio {
        let hub = LoopbackHub(), clock = TestClock()
        var config = Messenger.Configuration.relay(clock)
        config.relaySyncDelay = syncDelay
        if shippingPacing {
            let shipping = Messenger.Configuration()
            config.relaySyncDelay = shipping.relaySyncDelay
            config.relayMinExchangeInterval = shipping.relayMinExchangeInterval
            config.relaySaveDelay = shipping.relaySaveDelay
        }
        let a = makePhone(hub, "Asha", configuration: config)
        let b = makePhone(hub, "Ben", configuration: config)
        let c = makePhone(hub, "Chidi", configuration: config)
        let ab = try befriend(a, b)
        await waitUntil("A and B confirmed relay keys") { a.messenger.canRelay(to: ab.aSeesB) && b.messenger.canRelay(to: ab.bSeesA) }
        let ac = try befriend(a, c)
        let cb = try befriend(c, b)
        hub.setInRange(false, a.transport, b.transport)
        if !linkCToB { hub.setInRange(false, c.transport, b.transport) }
        await waitUntil("A and B apart") { a.messenger.linkState(for: ab.aSeesB) == .outOfRange }
        return Trio(hub: hub, clock: clock, a: a, b: b, c: c, aSeesB: ab.aSeesB, bSeesA: ab.bSeesA,
                    aSeesC: ac.aSeesB, cSeesB: cb.aSeesB, bSeesC: cb.bSeesA)
    }
}

@MainActor
@Suite struct RelayReviewTests {
    // P1: a stop()/teardown inside the relaySyncDelay window leaves `relaySyncScheduled` true forever.
    @Test func relaySyncFlagStuckAfterTeardown() async throws {
        let t = try await Trio.make(linkCToB: false)
        t.a.messenger.scheduleRelaySync()      // e.g. a receipt or a carried envelope just arrived
        t.a.messenger.stop()                    // within 5 ms: user toggles a setting / Bluetooth goes off
        t.a.messenger.start()
        await waitUntil("A and C linked again") { t.a.messenger.relayCarriersInRange.contains(t.aSeesC) }
        // A message written now, with Chidi linked and relaying on both sides.
        let sent = try #require(t.a.messenger.send("after the restart", to: t.aSeesB))
        #expect(t.a.messenger.relayHandoffs[sent.id] != nil, "sealed")
        // Adapted: wait instead of a fixed pause (the suite runs tests side by side on the main actor).
        // With the bug the flag stays set and this never happens.
        await waitUntil("offered to the linked carrier") { t.c.messenger.carriedMailCount == 1 }
    }

    @Test func controlRestartWithoutPendingSync() async throws {
        let t = try await Trio.make(linkCToB: false)
        t.a.messenger.stop()
        t.a.messenger.start()
        await waitUntil("A and C linked again") { t.a.messenger.relayCarriersInRange.contains(t.aSeesC) }
        _ = try #require(t.a.messenger.send("after the restart", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
    }

    // P2: one text too big for 8,192 bytes stops every later message to that contact from being sealed.
    @Test func oversizeMessageBlocksLaterSealing() async throws {
        let t = try await Trio.make(linkCToB: false)
        let huge = String(repeating: "👨‍👩‍👧‍👦", count: 400) // 400 characters, 10,000 bytes
        _ = try #require(t.a.messenger.send(huge, to: t.aSeesB))
        let normal = try #require(t.a.messenger.send("short and relayable", to: t.aSeesB))
        await pause(200)
        #expect(t.a.messenger.relayHandoffs[normal.id] != nil, "the short message was never sealed")
    }

    // P3: deleting unsent messages raises the floor although the recipient never saw them, so the
    // sender seals past the recipient's 256-tag window.
    @Test func deletionRaisesFloorPastRecipientWindow() throws {
        var q = RPair()
        for _ in 0..<200 {
            let e = q.seal()
            let id = try #require(e).messageID
            _ = q.a.removeOutbox(messageID: id)            // the user deletes the unsent message
        }
        var next: [RelayOutgoing] = []
        while let e = q.seal() { next.append(e) }
        let lastEntry = try #require(next.last)
        let last = try #require(RelayEnvelope(parsing: lastEntry.envelope))
        // Adapted after the fix: deleting copies no longer moves the window, so sealing stops at 255,
        // the last index Ben can recognise, and that one opens.
        #expect(lastEntry.index == 255)
        let result = q.b.open(last, now: q.now)
        #expect(result != .notMine, "index 255 must be inside Ben's window (0...255)")
    }

    // P4: one contact's junk fills the whole byte quota; real mail from anyone else is refused.
    // Adapted: deposits now name the contact that handed them over (as Messenger does).
    @Test func oneDepositorFillsTheWholeCarryQuota() throws {
        var carrier = RelayState()
        let expires = RelayEnvelope.expiresHour(at: Date())
        func junk() -> RelayEnvelope {
            var bytes = [UInt8](repeating: 0, count: 8192)
            bytes[0] = 1
            for i in 1..<33 { bytes[i] = UInt8.random(in: 0...255) }
            withUnsafeBytes(of: expires.bigEndian) { for (k, v) in $0.enumerated() { bytes[33 + k] = v } }
            return RelayEnvelope(parsing: Data(bytes))!
        }
        let mallory = ContactID(rawValue: "mallory"), honestFriends = (0..<10).map { ContactID(rawValue: "friend\($0)") }
        var junkCount = 0
        for _ in 0..<RelayLimits.perDepositorMax where carrier.carry(junk(), from: mallory) { junkCount += 1 }
        #expect(junkCount * 8192 <= RelayLimits.perDepositorMaxBytes, "one contact keeps at most a fifth of the store")
        var p = RPair()
        let sealedReal = p.seal("real mail")
        let realEntry = try #require(sealedReal)
        let real = try #require(RelayEnvelope(parsing: realEntry.envelope))
        let accepted = carrier.carry(real, from: honestFriends[0])
        #expect(accepted)
        // Honest 8 KB envelopes from everyone else: how many still fit?
        var honest = 0
        for i in 0..<100 where carrier.carry(junk(), from: honestFriends[i % 10]) { honest += 1 }
        #expect(honest >= 50, "after one contact's junk only \(honest) honest 8 KB envelopes fit")

        // After a restart the phone no longer knows who gave what. Mallory deposits a fresh fifth,
        // yet the others' next deposits still fit, by pushing out the oldest (unattributed) mail.
        var restarted = RelayState(keysData: nil, carryData: carrier.encodedCarry())
        var again = 0
        for _ in 0..<RelayLimits.perDepositorMax where restarted.carry(junk(), from: mallory) { again += 1 }
        #expect(again * 8192 <= RelayLimits.perDepositorMaxBytes)
        var honestAfter = 0
        for i in 0..<50 where restarted.carry(junk(), from: honestFriends[i % 10]) { honestAfter += 1 }
        #expect(honestAfter == 50)
        #expect(restarted.usage(of: mallory.rawValue).bytes <= RelayLimits.perDepositorMaxBytes)
        #expect(restarted.carriedBytes <= RelayLimits.carryMaxBytes)
    }

    // P5: an honest carrier on a slow link trips the incoming rate limit and its link is closed.
    @Test func honestTrickleTripsRateLimit() async throws {
        let t = try await Trio.make(shippingPacing: true)   // the shipping defaults
        var held: [Data] = []
        var passthrough = false
        let aToken = t.a.token, cToken = t.c.token
        var cToB = 0, bToC = 0
        let bToken = t.b.token
        t.hub.intercept = { data, from, to in
            if from == cToken && to == bToken { cToB += 1 }
            if from == bToken && to == cToken { bToC += 1 }
            if !(from == aToken && to == cToken) { return data }
            if passthrough { passthrough = false; return data }
            held.append(data); return nil
        }
        // A slow A→C link (one frame per 60 ms), as on Bluetooth LE.
        let drain = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !held.isEmpty else { continue }
                let frame = held.removeFirst()
                passthrough = true
                try? t.a.transport.send(frame, to: cToken)
                passthrough = false
            }
        }
        defer { drain.cancel() }
        let t0 = ContinuousClock.now
        var log: [String] = []
        t.c.messenger.onRelayActivity = { act in
            switch act {
            case .carried: log.append("C carried @\((ContinuousClock.now - t0).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - t0).components.seconds * 1000)ms")
            case .handedOver(_, let to): log.append("C handed to \(to == t.cSeesB ? "B" : "A") @\((ContinuousClock.now - t0).components.seconds * 1000 + (ContinuousClock.now - t0).components.attoseconds / 1_000_000_000_000_000)ms")
            default: break
            }
        }
        for i in 0..<60 { _ = t.a.messenger.send("message \(i)", to: t.aSeesB) }
        var cbDropped = false
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if t.b.messenger.linkState(for: t.bSeesC) != .connected || t.c.messenger.linkState(for: t.cSeesB) != .connected {
                cbDropped = true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        print(log.prefix(12).joined(separator: "\n"))
        print("P5 frames C->B \(cToB), B->C \(bToC), B has \(t.b.messenger.messages(for: t.bSeesA).count) messages, held left \(held.count)")
        #expect(!cbDropped, "the honest C–B link was closed as a protocol violation")
    }

    // H2, harder: EVERY link is slow in both directions (one frame per 30 ms each way, roughly a
    // busy Bluetooth LE link), with the shipping pacing. 60 messages must all arrive and be confirmed,
    // and no honest link may be closed for breaking a rule.
    @Test func honestTrafficOnSlowLinksNeverTripsALimit() async throws {
        let t = try await Trio.make(shippingPacing: true)
        var queues: [String: [Data]] = [:]
        var releasing = false
        var released = 0
        let started = ContinuousClock.now
        let transports = [t.a.token: t.a.transport, t.b.token: t.b.transport, t.c.token: t.c.transport]
        t.hub.intercept = { data, from, to in
            // Only the one frame being released passes; anything sent in reaction to it (delivery is
            // synchronous on the loopback radio) joins the queue like every other frame.
            if releasing { releasing = false; return data }
            queues["\(from.rawValue)>\(to.rawValue)", default: []].append(data)
            return nil
        }
        let pump = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                for key in Array(queues.keys) where !(queues[key]?.isEmpty ?? true) {
                    let parts = key.split(separator: ">").map(String.init)
                    let frame = queues[key]!.removeFirst()
                    releasing = true
                    try? transports[PeerToken(rawValue: parts[0])]?.send(frame, to: PeerToken(rawValue: parts[1]))
                    releasing = false
                    released += 1
                }
            }
        }
        defer { pump.cancel() }
        var drops = 0
        let watch = Task { @MainActor in
            var wasUp = true
            while !Task.isCancelled {
                let up = t.c.messenger.linkState(for: t.cSeesB) == .connected && t.a.messenger.linkState(for: t.aSeesC) == .connected
                if wasUp && !up { drops += 1 }
                wasUp = up
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { watch.cancel() }
        let sent = (0..<60).compactMap { t.a.messenger.send("slow \($0)", to: t.aSeesB) }
        await waitUntil("Ben has all 60", timeout: .seconds(40)) { t.b.messenger.messages(for: t.bSeesA).count == 60 }
        await waitUntil("Asha sees all Delivered", timeout: .seconds(40)) {
            t.a.messenger.messages(for: t.aSeesB).filter { $0.status == .delivered }.count == sent.count
        }
        print("slow links: \(released) frames released one per 30 ms per direction, \(ContinuousClock.now - started)")
        #expect(released > 120, "the throttle was in the path")
        #expect(drops == 0, "an honest link was closed")
    }

    // P6: a blocked contact still receives messages sealed before the block, and the sender sees Delivered.
    @Test func blockedContactStillGetsRelayedMail() async throws {
        let t = try await Trio.make(linkCToB: false)
        let sent = try #require(t.a.messenger.send("written before blocking", to: t.aSeesB))
        await waitUntil("Chidi carries it") { t.c.messenger.carriedMailCount == 1 }
        t.a.messenger.setBlocked(true, for: t.aSeesB)
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await pause(300)
        #expect(!t.b.messenger.messages(for: t.bSeesA).contains { $0.id == sent.id }, "blocked contact received it")
        #expect(t.a.messenger.messages(for: t.aSeesB).first?.status != .delivered)
    }

    // P7: "Off" is not fail-closed: an unreadable relay-keys file turns relaying back on.
    @Test func offSettingRevertsToFriendsWhenKeysUnreadable() {
        var keys = RelayKeys(); keys.carryMode = .off
        var data = (try? JSONEncoder().encode(keys)) ?? Data()
        data.removeLast() // truncated / corrupt / unreadable
        let loaded = RelayState(keysData: data, carryData: nil)
        #expect(loaded.keys.carryMode == .off)
    }

    // P8: with asymmetric confirmation the peer retires the generation still in use after 7 days.
    @Test func unconfirmedSideKeepsUsingAGenerationThePeerRetires() throws {
        var p = RPair()
        // A new direct link: Ben installs g2 and confirms it; Asha never got Ben's relaySync (link dropped).
        let later = p.now.addingTimeInterval(3600)
        _ = p.b.installGeneration(contact: p.bSeesA, root: SymmetricKey(size: .bits256), ownIdentityKey: p.bKey,
                                  peerIdentityKey: p.aKey, now: later)
        let day8 = p.now.addingTimeInterval(8 * 86_400)
        _ = p.b.purge(now: day8)
        let sealed = p.a.seal(text: "day 8", messageID: UUID(), sentAt: day8, to: p.aSeesB, now: day8)
        let entry = try #require(sealed)
        #expect(p.a.hasConfirmedGeneration(p.aSeesB), "Asha's UI still says relaying is available")
        let env = try #require(RelayEnvelope(parsing: entry.envelope))
        let result = p.b.open(env, now: day8)
        #expect(result != .notMine, "Ben can no longer open anything Asha seals")
    }

    // P9: main-thread cost of the per-packet save and of `isHeld` with a full own outbox.
    @Test func perPacketCosts() throws {
        var carrier = RelayState()
        let expires = RelayEnvelope.expiresHour(at: Date())
        for _ in 0..<1000 {
            var bytes = [UInt8](repeating: 0, count: 2048); bytes[0] = 1
            for i in 1..<33 { bytes[i] = UInt8.random(in: 0...255) }
            withUnsafeBytes(of: expires.bigEndian) { for (k, v) in $0.enumerated() { bytes[33 + k] = v } }
            _ = carrier.carry(RelayEnvelope(parsing: Data(bytes))!)
        }
        for i in 0..<RelayLimits.maxSeen {
            var id = Data(count: 8); withUnsafeBytes(of: UInt64(i).bigEndian) { id = Data($0) }
            carrier.markSeen(id, receiptHash: Data(count: 16), now: Date())
        }
        let clock = ContinuousClock()
        let encode = clock.measure { for _ in 0..<100 { _ = carrier.encodedCarry() } }
        var sender = RPair()
        var own = 0
        while sender.seal(String(repeating: "y", count: 3000)) != nil { own += 1 }
        let ids = (0..<512).map { _ in Data((0..<8).map { _ in UInt8.random(in: 0...255) }) }
        let held = clock.measure { for id in ids { _ = sender.a.isHeld(id) } }
        let keysTime = clock.measure { for _ in 0..<10 { _ = sender.a.encodedKeys() } }
        print("P9 encodedKeys x10 with \(own) own 8 KB envelopes: \(keysTime), size \(sender.a.encodedKeys().count) bytes")
        print("P9 encodedCarry x100 (one 100-envelope batch): \(encode); isHeld x512 over \(own) own 8 KB envelopes (one offer): \(held)")
    }

    // P10: a contact can ask for the same envelopes again and again; each request is answered in full.
    @Test func repeatedWantsAreAnsweredEveryTime() async throws {
        let t = try await Trio.make(linkCToB: false)
        var stranger = RPair()
        var ids: [Data] = []
        for _ in 0..<20 {
            let sealed = stranger.seal(String(repeating: "z", count: 3000))   // 8 KB envelopes
            let entry = try #require(sealed)
            let env = try #require(RelayEnvelope(parsing: entry.envelope))
            _ = t.c.messenger.relay.carry(env)
            ids.append(env.id)
        }
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben carries the 20") { t.b.messenger.carriedMailCount == 20 }
        var bytesToB = 0
        let cToken = t.c.token, bToken = t.b.token
        t.hub.intercept = { data, from, to in
            guard from == cToken, to == bToken else { return data }
            bytesToB += data.count
            return nil                       // Ben's side ignores the answers
        }
        let token = try #require(t.b.messenger.links.first { $0.value.contactID == t.bSeesC }?.key)
        let want = ids.reduce(Data(), +)     // 160 bytes
        for _ in 0..<50 { try? t.b.messenger.send(.relayWant(want), to: token) }
        let handed = t.c.messenger.relay.carried.map(\.handedOut).max() ?? 0
        print("P10 50 wants of \(want.count) bytes each -> \(bytesToB) bytes queued to Ben; handedOut max \(handed)")
        #expect(bytesToB < 1_000_000, "\(bytesToB) bytes answered")
        #expect(handed <= RelayLimits.maxHandOuts)
        #expect(t.c.messenger.linkState(for: t.cSeesB) != .connected, "C did not treat the repeats as a violation")
    }
}

// MARK: - Further tests written while fixing the review findings

@MainActor
@Suite struct RelayReviewFixTests {
    /// L2: an unreadable relay store keeps relaying off, is not overwritten, and an explicit choice ends that.
    @Test func anUnreadableRelayStoreFailsClosed() async throws {
        let hub = LoopbackHub(), clock = TestClock()
        let store = InMemoryPersistence()
        store.save(blob: Data("{not json".utf8), named: Messenger.relayKeysBlob, completion: nil)
        let a = makePhone(hub, "Asha", persistence: store, configuration: .relay(clock))
        let b = makePhone(hub, "Ben", configuration: .relay(clock))
        #expect(a.messenger.carryMode == .off)
        #expect(!a.messenger.announcedFeatures.contains(Feature.relay))
        let ids = try befriend(a, b)
        _ = a.messenger.send("hello", to: ids.aSeesB)
        a.messenger.flushRelaySaves()
        #expect(store.load(blob: Messenger.relayKeysBlob) == Data("{not json".utf8), "the unreadable store was left alone")
        a.messenger.setCarryMode(.friends)
        #expect(a.messenger.carryMode == .friends)
        let saved = try #require(store.load(blob: Messenger.relayKeysBlob))
        #expect(try JSONDecoder().decode(RelayKeys.self, from: saved).carryMode == .friends)
    }

    /// L8 / write-ahead with the real file store: an envelope is not offered until its chain is on disk,
    /// and a fresh load from the same folder continues the chain without reusing an index.
    @Test func writeAheadWithTheFileStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = LoopbackHub(), clock = TestClock()
        let files = FilePersistence(directory: folder)
        let aTransport = hub.makeTransport(token: "asha-files")
        let a = Messenger(transport: aTransport, persistence: files, identityStore: InMemoryIdentityStore(),
                          configuration: .relay(clock))
        a.completeOnboarding(displayName: "Asha")
        a.start()
        let b = makePhone(hub, "Ben", configuration: .relay(clock))
        let peer = try #require(a.nearbyPeers.first { $0.id == b.token })
        a.connect(to: peer)
        let request = try #require(b.messenger.requests.first)
        b.messenger.accept(request)
        let id = try #require(a.contacts.first).id
        await waitUntil("keys confirmed") { a.canRelay(to: id) }
        hub.setInRange(false, aTransport, b.transport)
        await waitUntil("apart") { a.linkState(for: id) == .outOfRange }
        _ = a.send("one", to: id)
        let sealed = try #require(a.relay.keys.outbox.first)
        #expect(a.relayUnpersisted.contains(sealed.envelopeID), "not offerable before the file write finished")
        await waitUntil("written") { a.relayUnpersisted.isEmpty }
        files.flush()
        let reloaded = RelayState(keysData: files.load(blob: Messenger.relayKeysBlob), carryData: nil)
        #expect(reloaded.keys.outbox.map(\.index) == [0])
        #expect(reloaded.keys.pairs[id.rawValue]?.send?.index == 1, "the advanced chain is what is on disk")
    }

    @Test func eraseCarriedMailForgetsWhatWasSeenToo() throws {
        var state = RelayState()
        var p = RPair()
        let sealed = p.seal("x")
        let entry = try #require(sealed)
        let envelope = try #require(RelayEnvelope(parsing: entry.envelope))
        state.markSeen(envelope.id, receiptHash: envelope.receiptHash, now: Date())
        let carried = state.carry(envelope)
        #expect(carried)
        state.eraseCarried()
        #expect(state.carried.isEmpty && state.seen.isEmpty && state.receipts.isEmpty)
    }

    /// M6 end to end: each phone tells the other once it seals under the new generation.
    @Test func confirmationReachesTheOtherPhone() async throws {
        let hub = LoopbackHub(), clock = TestClock()
        let a = makePhone(hub, "Asha", configuration: .relay(clock))
        let b = makePhone(hub, "Ben", configuration: .relay(clock))
        let ids = try befriend(a, b)
        await waitUntil("both confirmed") {
            b.messenger.relay.keys.pairs[ids.bSeesA.rawValue]?.receive.last?.peerConfirmedAt != nil
                && a.messenger.relay.keys.pairs[ids.aSeesB.rawValue]?.receive.last?.peerConfirmedAt != nil
        }
    }

    /// M5 call sites: blocking or removing a contact, and erasing everything, tell the radio to forget.
    @Test func blockingRemovingAndErasingTellTheRadioToForget() async throws {
        let hub = LoopbackHub(), clock = TestClock()
        let a = makePhone(hub, "Asha", configuration: .relay(clock))
        let b = makePhone(hub, "Ben", configuration: .relay(clock))
        let c = makePhone(hub, "Chidi", configuration: .relay(clock))
        let ab = try befriend(a, b)
        let ac = try befriend(a, c)
        a.messenger.setBlocked(true, for: ab.aSeesB)
        #expect(a.transport.forgotten.contains(b.token))
        // The blocked phone shows up again: the radio is told to forget it straight away.
        let before = a.transport.forgotten.count
        hub.setReachable(false, b.transport)
        hub.setReachable(true, b.transport)
        #expect(a.transport.forgotten.count > before)
        a.messenger.removeContact(ac.aSeesB)
        #expect(a.transport.forgotten.contains(c.token))
        a.messenger.eraseEverything()
        #expect(a.transport.forgotAllCount == 1)
    }
}

@MainActor
@Suite struct RelayRepeatTests {
    /// H1: each envelope is handed over at most once per link; asking again closes the link.
    @Test func askingAgainForAnEnvelopeAlreadyHandedOverClosesTheLink() async throws {
        let t = try await Trio.make(linkCToB: false)
        var stranger = RPair()
        let sealed = stranger.seal("someone else's")
        let entry = try #require(sealed)
        let envelope = try #require(RelayEnvelope(parsing: entry.envelope))
        let carried = t.c.messenger.relay.carry(envelope)
        #expect(carried)
        t.hub.setInRange(true, t.c.transport, t.b.transport)
        await waitUntil("Ben took it") { t.b.messenger.carriedMailCount == 1 }
        #expect(t.c.messenger.relay.carried.first?.handedOut == 1)
        let token = try #require(t.b.messenger.links.first { $0.value.contactID == t.bSeesC }?.key)
        try t.b.messenger.send(.relayWant(envelope.id), to: token)
        await waitUntil("Chidi closed the link") { t.c.messenger.linkState(for: t.cSeesB) != .connected }
        #expect(t.c.messenger.relay.carried.first?.handedOut == 1, "not handed over a second time")
    }
}

/// Counts relay store writes (M7).
final class CountingPersistence: Persistence, @unchecked Sendable {
    let inner = InMemoryPersistence()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    func load() -> PersistedState { inner.load() }
    func save(profile: Profile) { inner.save(profile: profile) }
    func save(contacts: [Contact]) { inner.save(contacts: contacts) }
    func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?) {
        inner.save(conversation: conversation, for: id, completion: completion)
    }
    func deleteConversation(for id: ContactID) { inner.deleteConversation(for: id) }
    func load(blob name: String) -> Data? { inner.load(blob: name) }
    func save(blob: Data, named name: String, completion: (@Sendable (Bool) -> Void)?) {
        lock.withLock { counts[name, default: 0] += 1 }
        inner.save(blob: blob, named: name, completion: completion)
    }
    func eraseAll() { inner.eraseAll() }
    func flush() {}
}

@MainActor
@Suite struct RelayCostTests {
    /// M7: a carrier receiving a batch of 100 envelopes writes its carry store a handful of times,
    /// not once per envelope (shipping save delay of one second).
    @Test func aBatchOfEnvelopesIsSavedTogether() async throws {
        let hub = LoopbackHub(), clock = TestClock()
        var config = Messenger.Configuration.relay(clock)
        config.relaySaveDelay = Messenger.Configuration().relaySaveDelay
        let a = makePhone(hub, "Asha", configuration: config)
        let store = CountingPersistence()
        let c = Messenger(transport: hub.makeTransport(token: "chidi-count"), persistence: store,
                          identityStore: InMemoryIdentityStore(), configuration: config)
        c.completeOnboarding(displayName: "Chidi")
        c.start()
        // 100 envelopes Asha carries for strangers, then Asha meets Chidi.
        var stranger = RPair()
        for i in 0..<100 {
            let sealed = stranger.seal("for someone else \(i)")
            let entry = try #require(sealed)
            let envelope = try #require(RelayEnvelope(parsing: entry.envelope))
            _ = a.messenger.relay.carry(envelope)
            for index in stranger.a.keys.outbox.indices { stranger.a.keys.outbox[index].expired = true }
        }
        let before = store.count(Messenger.relayCarryBlob)
        let peer = try #require(a.messenger.nearbyPeers.first { $0.id.rawValue == "chidi-count" })
        a.messenger.connect(to: peer)
        c.accept(try #require(c.requests.first))
        await waitUntil("Chidi carries all 100") { c.carriedMailCount == 100 }
        await waitUntil("saved", timeout: .seconds(5)) { store.count(Messenger.relayCarryBlob) > before }
        await pause(200)
        let writes = store.count(Messenger.relayCarryBlob) - before
        print("carry store writes for a 100-envelope batch: \(writes)")
        #expect(writes >= 1 && writes <= 4)
    }
}
