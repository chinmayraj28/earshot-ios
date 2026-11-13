import Foundation
import Testing
@testable import EarshotKit

/// Waiting texts go out through a bounded window when a link comes up, so a backlog can never
/// overflow the radio's per-phone send queue (BluetoothTransport closes a link above 1 MiB).
@MainActor
@Suite struct TextWindowTests {
    /// 2,000 characters of a three-byte script: about 6 KB of UTF-8 per message.
    static func longText(_ index: Int) -> String { "\(index): " + String(repeating: "語", count: 1990) }

    /// Asha writes `count` long texts while Ben is away, then the radio becomes slow (one frame per
    /// millisecond each way, 1 MiB queue cap) and Ben comes back.
    static func backlog(count: Int, configure: (inout Messenger.Configuration) -> Void = { _ in })
        async throws -> (hub: LoopbackHub, a: Phone, b: Phone, aSeesB: ContactID, bSeesA: ContactID, texts: [String]) {
        let hub = LoopbackHub()
        var config = Messenger.Configuration.fast
        config.ackTimeout = .seconds(5)
        // A faster flood allowance on both sides than the shipping 60 + 5/s, so 300 texts take
        // seconds rather than a minute; the sender still keeps under the receiver's allowance.
        config.incomingRate = 200
        config.outgoingTextRate = 180
        // These tests are about the direct path; relaying would also seal 200 envelopes of 8 KB on
        // the main actor, which only slows every other test running alongside.
        config.announcesRelay = false
        configure(&config)
        let a = makePhone(hub, "Asha", configuration: config)
        let b = makePhone(hub, "Ben", configuration: config)
        let ids = try befriend(a, b)
        hub.setInRange(false, a.transport, b.transport)
        await waitUntil("apart") { a.messenger.linkState(for: ids.aSeesB) == .outOfRange }
        let texts = (0..<count).map(longText)
        for text in texts { _ = a.messenger.send(text, to: ids.aSeesB) }
        #expect(a.messenger.messages(for: ids.aSeesB).allSatisfy { $0.status == .waiting })
        hub.pacedFrameInterval = .milliseconds(1)
        hub.perPeerQueueCap = 1024 * 1024
        return (hub, a, b, ids.aSeesB, ids.bSeesA, texts)
    }

    @Test func threeHundredLongWaitingTextsAllArriveInOrderWithoutClosingTheLink() async throws {
        let t = try await Self.backlog(count: 300)
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("linked") { t.b.messenger.linkState(for: t.bSeesA) == .connected }
        var drops = 0
        let watch = Task { @MainActor in
            var wasUp = true
            while !Task.isCancelled {
                let up = t.b.messenger.linkState(for: t.bSeesA) == .connected
                if wasUp && !up { drops += 1 }
                wasUp = up
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { watch.cancel() }
        await waitUntil("Ben has all 300", timeout: .seconds(60)) { t.b.messenger.messages(for: t.bSeesA).count == 300 }
        print("300-text backlog: link drops \(drops)")
        #expect(drops == 0, "an honest link was closed (radio cap or the receiver's message allowance)")
        await waitUntil("all Delivered", timeout: .seconds(20)) {
            t.a.messenger.messages(for: t.aSeesB).allSatisfy { $0.status == .delivered }
        }
        #expect(t.b.messenger.messages(for: t.bSeesA).map(\.text) == t.texts)
        #expect(t.hub.queueCapClosures == 0, "the link was closed for overflowing the radio queue")
    }

    /// Control: without the window (everything at once) the same backlog overflows the cap,
    /// which is what the window prevents.
    @Test func withoutTheWindowTheSameBacklogOverflowsTheQueue() async throws {
        let t = try await Self.backlog(count: 300) {
            $0.maxTextsInFlight = 10_000
            $0.maxTextBytesInFlight = .max
            $0.outgoingTextBurst = 100_000
            $0.outgoingTextRate = 1_000_000
        }
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("the radio closed the link at least once") { t.hub.queueCapClosures > 0 }
        t.a.messenger.stop()
        t.b.messenger.stop()
    }

    @Test func aLinkDroppedMidwayFinishesLaterWithoutDuplicates() async throws {
        let t = try await Self.backlog(count: 120)
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("some arrived", timeout: .seconds(30)) { t.b.messenger.messages(for: t.bSeesA).count >= 30 }
        t.hub.dropConnection(t.a.transport, t.b.transport) // reconnects by itself: still in range
        await waitUntil("Ben has all 120", timeout: .seconds(60)) { t.b.messenger.messages(for: t.bSeesA).count >= 120 }
        await waitUntil("all Delivered", timeout: .seconds(20)) {
            t.a.messenger.messages(for: t.aSeesB).allSatisfy { $0.status == .delivered }
        }
        await pause(100)
        let received = t.b.messenger.messages(for: t.bSeesA).map(\.text)
        #expect(received.count == 120, "no duplicates")
        #expect(received == t.texts, "in order")
        #expect(t.hub.queueCapClosures == 0)
    }

    @Test func aTextWrittenDuringTheBacklogQueuesBehindIt() async throws {
        let t = try await Self.backlog(count: 80)
        t.hub.setInRange(true, t.a.transport, t.b.transport)
        await waitUntil("draining", timeout: .seconds(30)) { t.b.messenger.messages(for: t.bSeesA).count >= 10 }
        #expect(t.b.messenger.messages(for: t.bSeesA).count < 80, "still draining when the new text is written")
        _ = t.a.messenger.send("written just now", to: t.aSeesB)
        await waitUntil("Ben has all 81", timeout: .seconds(60)) { t.b.messenger.messages(for: t.bSeesA).count == 81 }
        #expect(t.b.messenger.messages(for: t.bSeesA).map(\.text) == t.texts + ["written just now"])
    }

    /// With the shipping numbers: a backlog of 70 texts (more than the receiver's burst of 60) goes out
    /// at the sender's own pace and never trips the receiver's flood limit.
    @Test func aBacklogLongerThanTheReceiversBurstIsPacedNotDropped() async throws {
        let hub = LoopbackHub()
        var config = Messenger.Configuration.fast
        config.ackTimeout = .seconds(5)
        config.announcesRelay = false
        let shipping = Messenger.Configuration()
        #expect(shipping.outgoingTextBurst < shipping.incomingBurst && shipping.outgoingTextRate < shipping.incomingRate)
        let a = makePhone(hub, "Asha", configuration: config)
        let b = makePhone(hub, "Ben", configuration: config)
        let ids = try befriend(a, b)
        hub.setInRange(false, a.transport, b.transport)
        await waitUntil("apart") { a.messenger.linkState(for: ids.aSeesB) == .outOfRange }
        let texts = (0..<70).map { "short \($0)" }
        for text in texts { _ = a.messenger.send(text, to: ids.aSeesB) }
        hub.setInRange(true, a.transport, b.transport)
        await waitUntil("linked") { b.messenger.linkState(for: ids.bSeesA) == .connected }
        var drops = 0
        let watch = Task { @MainActor in
            var wasUp = true
            while !Task.isCancelled {
                let up = b.messenger.linkState(for: ids.bSeesA) == .connected
                if wasUp && !up { drops += 1 }
                wasUp = up
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { watch.cancel() }
        await waitUntil("Ben has all 70", timeout: .seconds(15)) { b.messenger.messages(for: ids.bSeesA).count == 70 }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == texts)
        #expect(drops == 0, "the receiver's flood limit closed an honest link")
    }

    /// Fails the first `failures` conversation saves, so no receipt is ever sent for those messages.
    final class ForgetfulPersistence: Persistence, @unchecked Sendable {
        let inner = InMemoryPersistence()
        private let lock = NSLock()
        private var failures: Int
        init(failures: Int) { self.failures = failures }
        func load() -> PersistedState { inner.load() }
        func save(profile: Profile) { inner.save(profile: profile) }
        func save(contacts: [Contact]) { inner.save(contacts: contacts) }
        func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?) {
            let fail = lock.withLock { () -> Bool in
                guard failures > 0, !conversation.messages.isEmpty else { return false }
                failures -= 1
                return true
            }
            if fail { completion?(false) } else { inner.save(conversation: conversation, for: id, completion: completion) }
        }
        func deleteConversation(for id: ContactID) { inner.deleteConversation(for: id) }
        func load(blob name: String) -> Data? { inner.load(blob: name) }
        func save(blob: Data, named name: String, completion: (@Sendable (Bool) -> Void)?) {
            inner.save(blob: blob, named: name, completion: completion)
        }
        func eraseAll() { inner.eraseAll() }
        func flush() {}
    }

    @Test func aReceiptThatNeverComesDoesNotBlockTheWindow() async throws {
        // Ben's phone cannot save the first two texts, so it never confirms them. With a window of
        // two, they would block everything behind them; instead they are marked "Not delivered" after
        // ackTimeout, their places free up, and the other four go out and are confirmed.
        let hub = LoopbackHub()
        var config = Messenger.Configuration.fast
        config.maxTextsInFlight = 2
        let a = makePhone(hub, "Asha", configuration: config)
        let bTransport = hub.makeTransport(token: "ben-forgetful")
        let b = Messenger(transport: bTransport, persistence: ForgetfulPersistence(failures: 2),
                          identityStore: InMemoryIdentityStore(), configuration: config)
        b.completeOnboarding(displayName: "Ben")
        b.start()
        let peer = try #require(a.messenger.nearbyPeers.first { $0.id == bTransport.token })
        a.messenger.connect(to: peer)
        b.accept(try #require(b.requests.first))
        let id = try #require(a.messenger.contacts.first).id
        await pause(30)
        for i in 0..<6 { _ = a.messenger.send("text \(i)", to: id) }
        await waitUntil("four Delivered, two Not delivered") {
            let statuses = a.messenger.messages(for: id).map(\.status)
            return statuses.filter { $0 == .delivered }.count == 4 && statuses.filter { $0 == .failed }.count == 2
        }
        #expect(a.messenger.messages(for: id).prefix(2).allSatisfy { $0.status == .failed })
    }
}
