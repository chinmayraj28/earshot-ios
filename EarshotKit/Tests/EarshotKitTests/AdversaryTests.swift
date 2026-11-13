import Foundation
import Testing
@testable import EarshotKit

/// A hand-driven device on the hub that speaks the wire protocol directly,
/// so tests can play someone misbehaving.
@MainActor
final class RawPeer {
    let transport: LoopbackTransport
    let identity = Identity()
    var handshake = Handshake()
    var channel: SecureChannel?
    var helloVersion: UInt8 = Handshake.version
    var acceptsInvitations = true
    var received: [Payload] = []
    var invitedBy: [PeerToken] = []
    var connected: [PeerToken] = []
    /// Identity keys other phones disclosed to this peer.
    var revealedIdentities: [Data] {
        received.compactMap { if case .auth(let auth) = $0 { auth.identityKey } else { nil } }
    }
    /// Identity presented in the proof step. Defaults to the peer's own.
    var claimedIdentityKey: Data?

    init(_ hub: LoopbackHub, name: String, nonce: Data = DiscoveryTag.makeNonce(), tag: Data = Data(count: 8)) {
        transport = hub.makeTransport(token: "raw-" + name)
        transport.eventHandler = { [weak self] in self?.handle($0) }
        transport.start(LocalAdvertisement(displayName: name, nonce: nonce, tag: tag, isVisible: true))
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .invited(let token, _):
            invitedBy.append(token)
            transport.respondToInvitation(from: token, accept: acceptsInvitations)
        case .connected(let token):
            connected.append(token)
            try? transport.send(Frame.hello(version: helloVersion, ephemeralKey: handshake.publicKey).encoded(), to: token)
        case .received(let data, let token):
            guard let frame = try? Frame(decoding: data) else { return }
            switch frame {
            case .hello(_, let remote):
                guard var channel = try? handshake.channel(remoteEphemeral: remote) else { return }
                let transcript = Handshake.transcript(signerEphemeral: handshake.publicKey, peerEphemeral: remote)
                let auth = Payload.auth(.init(identityKey: claimedIdentityKey ?? identity.publicKey, name: "Raw",
                                              signature: (try? identity.sign(transcript)) ?? Data()))
                if let sealed = try? channel.seal(auth.encoded()) {
                    try? transport.send(Frame.sealed(sealed).encoded(), to: token)
                }
                self.channel = channel
            case .sealed(let box):
                if let plain = try? channel?.open(box), let payload = try? Payload.decode(plain) { received.append(payload) }
            }
        default:
            break
        }
    }

    func send(_ payload: Payload, to token: PeerToken) throws {
        let sealed = try channel!.seal(payload.encoded())
        try transport.send(Frame.sealed(sealed).encoded(), to: token)
    }
}

@MainActor
@Suite struct AdversaryTests {
    @Test func strangerCannotBecomeAContactWithoutAPrompt() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let stranger = RawPeer(hub, name: "Stranger")
        let context = InviteContext(name: "Stranger", nonce: DiscoveryTag.makeNonce())
        stranger.transport.invite(a.token, context: context.encoded(), timeout: 5)

        #expect(a.messenger.requests.map(\.state) == [.pending])
        #expect(stranger.connected.isEmpty)
        #expect(a.messenger.contacts.isEmpty)
    }

    @Test func forgedReconnectionIsDroppedWithoutPromptOrLink() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        try befriend(a, b)
        hub.setReachable(false, b.transport)
        let stranger = RawPeer(hub, name: "Blake")
        // Old-style tag built from Blake's public beacon material, and a random one.
        let nonce = DiscoveryTag.makeNonce()
        for tag in [DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce), Data(count: PairTag.length)] {
            let context = InviteContext(name: "Blake", nonce: nonce, tag: tag)
            stranger.transport.invite(a.token, context: context.encoded(), timeout: 5)
        }
        #expect(a.messenger.requests.isEmpty)
        #expect(stranger.connected.isEmpty)
    }

    @Test func promptsAreCappedAndStaleTimersDoNotCancelNewRequests() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let crowd = (0..<8).map { RawPeer(hub, name: "Stranger \($0)") }
        for peer in crowd {
            peer.transport.invite(a.token, context: InviteContext(name: "S", nonce: DiscoveryTag.makeNonce()).encoded(), timeout: 5)
        }
        #expect(a.messenger.requests.count == 4)

        // First request lapses at the radio level; the same person asks again later.
        let again = makePhone(hub, "Morgan")
        a.messenger.requests.forEach(a.messenger.decline)
        again.messenger.connect(to: try #require(again.messenger.nearbyPeers.first { $0.id == a.token }))
        #expect(a.messenger.requests.count == 1)
        hub.expireInvites()
        again.messenger.requests.forEach(again.messenger.dismiss)
        await pause(700)
        again.messenger.connect(to: try #require(again.messenger.nearbyPeers.first { $0.id == a.token }))
        #expect(a.messenger.requests.count == 1)
        // The first request's expiry (1 s after it arrived) must leave the second alone.
        await pause(500)
        #expect(a.messenger.requests.map(\.state) == [.pending])
    }

    @Test func hiddenUserRevealsNoNameToAReplayedBeacon() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        try befriend(a, b)
        a.messenger.setVisible(false)
        hub.setReachable(false, b.transport)

        var contexts: [Data] = []
        let nonce = DiscoveryTag.makeNonce()
        let mallory = RawPeer(hub, name: "Blake", nonce: nonce,
                              tag: DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce))
        let previous = mallory.transport.eventHandler
        mallory.transport.eventHandler = { event in
            if case .invited(_, let context) = event { contexts.append(context) }
            previous?(event)
        }
        hub.setReachable(false, mallory.transport)
        hub.setReachable(true, mallory.transport)
        await waitUntil("Alex's phone reconnects on its own") { !contexts.isEmpty }
        for context in contexts {
            #expect(context.range(of: Data("Alex".utf8)) == nil)
            #expect(InviteContext.decode(context)?.name == nil)
        }
        await pause(100)
        #expect(mallory.revealedIdentities.isEmpty)
    }

    @Test func replayedBeaconsCannotLockOutARealContact() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake"), c = makePhone(hub, "Casey")
        try befriend(a, b)
        let casey = try befriend(a, c).aSeesB
        hub.setReachable(false, b.transport)
        hub.setReachable(false, c.transport)

        // Eight devices replay Blake's beacon and hold their links open without proving anything.
        let nonce = DiscoveryTag.makeNonce()
        let tag = DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce)
        let lurkers = (0..<8).map { RawPeer(hub, name: "Blake \($0)", nonce: nonce, tag: tag) }
        await pause(100)
        hub.setReachable(true, c.transport)
        await waitUntil("Casey still connects") { a.messenger.linkState(for: casey) == .connected }
        #expect(lurkers.allSatisfy { $0.revealedIdentities.isEmpty })
    }

    @Test func counterOverflowFrameDoesNotCrash() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        let id = try #require(a.messenger.contacts.first).id
        var frame = Data([2]) + Data(repeating: 0xFF, count: 8) + Data(count: 32)
        frame[frame.count - 1] = 1
        try raw.transport.send(frame, to: a.token)
        #expect(a.messenger.linkState(for: id) != .connected)
    }

    @Test func messageFloodClosesTheLink() async throws {
        let hub = LoopbackHub()
        var configuration = Messenger.Configuration.fast
        configuration.incomingBurst = 20
        configuration.incomingRate = 1
        let a = makePhone(hub, "Alex", configuration: configuration)
        let raw = RawPeer(hub, name: "Raw")
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        let id = try #require(a.messenger.contacts.first).id
        for index in 0..<200 {
            try? raw.send(.text(.init(id: UUID(), text: "spam \(index)")), to: a.token)
        }
        #expect(a.messenger.messages(for: id).count == 20)
        #expect(a.messenger.linkState(for: id) != .connected)
    }

    @Test func malformedInvitationIsDeclined() {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let stranger = RawPeer(hub, name: "Stranger")
        var disconnected = false
        let previous = stranger.transport.eventHandler
        stranger.transport.eventHandler = { event in
            if case .disconnected = event { disconnected = true }
            previous?(event)
        }
        stranger.transport.invite(a.token, context: Data("garbage".utf8), timeout: 5)
        #expect(a.messenger.requests.isEmpty)
        #expect(disconnected)
    }

    @Test func impostorReplayingAContactsBeaconFailsTheIdentityProof() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.send("before", to: ids.aSeesB)

        // Blake leaves. Mallory re-broadcasts a beacon that Alex's phone recognises as Blake.
        hub.setReachable(false, b.transport)
        let nonce = DiscoveryTag.makeNonce()
        let forgedTag = DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce)
        let mallory = RawPeer(hub, name: "Blake", nonce: nonce, tag: forgedTag)

        // Alex's phone tries to reconnect to "Blake" on its own…
        await waitUntil("auto-connect attempted") { !mallory.invitedBy.isEmpty }
        await waitUntil("handshake attempted") { !mallory.connected.isEmpty }
        await pause(100)

        // …but Mallory cannot sign as Blake, so no link forms and nothing is sent to her.
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)
        #expect(a.messenger.contacts.count == 1)
        a.messenger.send("after", to: ids.aSeesB)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .waiting)
        // All she ever gets is a knock: no name, no identity key, no messages.
        #expect(mallory.revealedIdentities.isEmpty)
        #expect(mallory.received.allSatisfy { if case .knock = $0 { true } else { false } })
    }

    @Test func impostorClaimingAContactsKeyWithoutItsSignatureIsRejected() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        hub.setReachable(false, b.transport)

        let nonce = DiscoveryTag.makeNonce()
        let mallory = RawPeer(hub, name: "Blake", nonce: nonce,
                              tag: DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce))
        mallory.claimedIdentityKey = b.messenger.identityKey // right key, wrong signer
        await waitUntil("handshake attempted") { !mallory.connected.isEmpty }
        await pause(100)
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)
        #expect(mallory.revealedIdentities.isEmpty)
    }

    @Test func impostorInvitingAsAContactLearnsNothing() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        hub.setReachable(false, b.transport)

        // Mallory relays a genuine reconnection invitation she overheard from Blake, so
        // Alex's phone accepts the radio link without a prompt. She still gets nothing.
        var genuine: Data?
        let mallory = RawPeer(hub, name: "Blake")
        hub.setReachable(true, b.transport)
        hub.dropConnection(a.transport, b.transport)
        let aNonce = try #require(a.messenger.currentNonceForTesting)
        let bNonce = try #require(b.messenger.currentNonceForTesting)
        genuine = InviteContext(nonce: bNonce, tag: PairTag.make(a.messenger.identityKey, b.messenger.identityKey,
                                                                 inviterNonce: bNonce, inviteeNonce: aNonce)).encoded()
        hub.setReachable(false, b.transport)
        mallory.transport.invite(a.token, context: try #require(genuine), timeout: 5)
        await pause(100)
        #expect(a.messenger.requests.isEmpty)
        #expect(!mallory.connected.isEmpty)
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)
        #expect(mallory.revealedIdentities.isEmpty)
    }

    @Test func tamperedFrameClosesTheLinkAndIsNotStored() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        hub.intercept = { data, from, _ in
            guard from == a.token else { return data }
            var changed = data
            changed[changed.count - 1] ^= 0xFF
            return changed
        }
        a.messenger.send("tamper with me", to: ids.aSeesB)
        #expect(b.messenger.messages(for: ids.bSeesA).isEmpty)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status != .delivered)

        hub.intercept = nil
        await waitUntil("recovers and delivers") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == ["tamper with me"])
    }

    @Test func incompatibleVersionIsReportedClearly() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let future = RawPeer(hub, name: "Future")
        future.helloVersion = 9
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        #expect(a.messenger.requests.map(\.state) == [.failed(.incompatibleVersion)])
        #expect(a.messenger.contacts.isEmpty)
    }

    @Test func silentPeerTimesOutDuringSetup() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let mute = RawPeer(hub, name: "Mute")
        hub.intercept = { data, from, _ in from == mute.transport.token ? nil : data }
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        #expect(a.messenger.requests.map(\.state) == [.connecting])
        await waitUntil("setup abandoned") { a.messenger.requests.map(\.state) == [.failed(.connectionLost)] }
        #expect(a.messenger.contacts.isEmpty)
    }

    @Test func connectedPeerCannotSendOversizedOrOutOfOrderPayloads() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        let id = try #require(a.messenger.contacts.first).id
        #expect(a.messenger.linkState(for: id) == .connected)

        try raw.send(.text(.init(id: UUID(), text: "fine")), to: a.token)
        #expect(a.messenger.messages(for: id).map(\.text) == ["fine"])

        try raw.send(.text(.init(id: UUID(), text: String(repeating: "x", count: Limits.maxMessageLength + 1))), to: a.token)
        #expect(a.messenger.messages(for: id).count == 1)
        #expect(a.messenger.linkState(for: id) != .connected)
    }

    @Test func receiptForUnknownMessageIsHarmless() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        let id = try #require(a.messenger.contacts.first).id
        try raw.send(.ack(UUID()), to: a.token)
        #expect(a.messenger.linkState(for: id) == .connected)
        #expect(a.messenger.messages(for: id).isEmpty)
    }
}

@MainActor
@Suite struct ResilienceTests {
    final class FlakyPersistence: Persistence, @unchecked Sendable {
        let inner = InMemoryPersistence()
        var failing = false
        func load() -> PersistedState { inner.load() }
        func save(profile: Profile) { inner.save(profile: profile) }
        func save(contacts: [Contact]) { inner.save(contacts: contacts) }
        func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?) {
            if failing { completion?(false) } else { inner.save(conversation: conversation, for: id, completion: completion) }
        }
        func deleteConversation(for id: ContactID) { inner.deleteConversation(for: id) }
        func eraseAll() { inner.eraseAll() }
        func flush() {}
    }

    final class LockedKeychain: IdentityStore, @unchecked Sendable {
        var locked = false
        var key: Data?
        var saves = 0
        func load() throws -> Data? {
            if locked { throw KeychainError(status: -25308) } // errSecInteractionNotAllowed
            return key
        }
        func save(_ key: Data) throws {
            if locked { throw KeychainError(status: -25308) }
            self.key = key
            saves += 1
        }
        func delete() { key = nil }
    }

    @Test func deliveredIsOnlyReportedOnceTheReceiverHasStoredTheMessage() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex")
        let store = FlakyPersistence()
        let bTransport = hub.makeTransport(token: "blake")
        let b = Messenger(transport: bTransport, persistence: store, identityStore: InMemoryIdentityStore(), configuration: .fast)
        b.completeOnboarding(displayName: "Blake")
        b.start()
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        b.accept(try #require(b.requests.first))
        let id = try #require(a.messenger.contacts.first).id

        store.failing = true
        let sent = try #require(a.messenger.send("will not be stored", to: id))
        #expect(a.messenger.messages(for: id).last?.status == .sending)
        await waitUntil("reported as not delivered") { a.messenger.messages(for: id).last?.status == .failed }

        store.failing = false
        a.messenger.retry(sent.id, in: id)
        // The receiver already holds it in memory, so the retry is confirmed straight away.
        #expect(a.messenger.messages(for: id).last?.status == .delivered)
    }

    @Test func lockedKeychainNeverReplacesTheIdentity() throws {
        let hub = LoopbackHub()
        let keychain = LockedKeychain()
        let original = Identity()
        keychain.key = original.rawRepresentation
        keychain.locked = true

        let messenger = Messenger(transport: hub.makeTransport(), persistence: InMemoryPersistence(),
                                  identityStore: keychain, configuration: .fast)
        messenger.completeOnboarding(displayName: "Alex")
        messenger.start()
        // Cannot go on air with a throwaway identity, and the stored key is untouched.
        guard case .unavailable(.failedToStart) = messenger.availability else {
            Issue.record("expected unavailable, got \(messenger.availability)")
            return
        }
        #expect(keychain.key == original.rawRepresentation && keychain.saves == 0)

        keychain.locked = false
        messenger.start()
        #expect(messenger.availability == .on)
        #expect(messenger.identityKey == original.publicKey)
    }

    @Test func contactInRangeKeepsBeingRetriedAfterTheQuickAttemptsRunOut() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        // Every frame is lost for a while: far longer than the three quick retries.
        hub.intercept = { _, _, _ in nil }
        hub.dropConnection(a.transport, b.transport)
        a.messenger.send("eventually", to: ids.aSeesB)
        await pause(1500)
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)

        hub.intercept = nil
        await waitUntil("recovers by itself", timeout: .seconds(4)) {
            a.messenger.messages(for: ids.aSeesB).last?.status == .delivered
        }
    }

    @Test func radioFailureReleasesLinksAndRecovers() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        a.transport.eventHandler?(.unavailable(.failedToStart("radio off")))
        #expect(a.messenger.availability == .unavailable(.failedToStart("radio off")))
        #expect(a.messenger.nearbyPeers.isEmpty)
        // The other phone is told, rather than talking to a phone that ignores it.
        #expect(b.messenger.linkState(for: ids.bSeesA) != .connected)

        a.messenger.start()
        await waitUntil("back on air and reconnected") { a.messenger.linkState(for: ids.aSeesB) == .connected }
    }

    @Test func grantingLocalNetworkAccessBringsEarshotBack() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.transport.eventHandler?(.unavailable(.localNetworkDenied))
        #expect(a.messenger.availability == .unavailable(.localNetworkDenied))
        a.transport.eventHandler?(.ready)
        #expect(a.messenger.availability == .on)
        await waitUntil("reconnected") { a.messenger.linkState(for: ids.aSeesB) == .connected }
        _ = b
    }

    @Test func longNamesFitTheRadioLimit() {
        let flags = String(repeating: "🇪🇺", count: 40)
        let name = Limits.sanitizedName(flags)
        #expect(name.utf8.count <= Limits.maxNameBytes && !name.isEmpty)
    }
}

@MainActor
@Suite struct DemoWorldTests {
    @Test func demoWorldBehavesLikeRealPhones() async throws {
        let world = DemoWorld(scenario: .populated, latency: nil)
        let me = world.messenger
        me.start()
        let maya = try #require(me.contacts.first { $0.displayName == "Jensen Huang" })
        let jonas = try #require(me.contacts.first { $0.displayName == "Alice Huang" })
        await waitUntil("Jensen connects") { me.linkState(for: maya.id) == .connected }
        #expect(me.linkState(for: jonas.id) == .outOfRange)
        #expect(me.nearbyPeers.filter { $0.contactID == nil }.map(\.displayName).sorted() == ["Aubrey Graham", "Tomás"])

        me.send("Are you there?", to: maya.id)
        #expect(me.messages(for: maya.id).last?.status == .delivered)
        await waitUntil("Jensen replies", timeout: .seconds(5)) { me.messages(for: maya.id).last?.direction == .incoming }

        world.setInRange(false, name: "Jensen Huang")
        #expect(me.linkState(for: maya.id) == .outOfRange)
        world.setInRange(true, name: "Jensen Huang")
        await waitUntil("Jensen reconnects") { me.linkState(for: maya.id) == .connected }

        world.receiveRequest()
        await waitUntil("incoming request", timeout: .seconds(5)) { me.requests.contains { $0.direction == .incoming } }
    }
}
