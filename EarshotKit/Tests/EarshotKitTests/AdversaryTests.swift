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
        let context = InviteContext(name: "Stranger", nonce: DiscoveryTag.makeNonce(), tag: Data(count: 8))
        stranger.transport.invite(a.token, context: context.encoded(), timeout: 5)

        #expect(a.messenger.requests.map(\.state) == [.pending])
        #expect(stranger.connected.isEmpty)
        #expect(a.messenger.contacts.isEmpty)
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

        // Mallory sends a request that looks like Blake reconnecting, so no prompt is shown.
        let nonce = DiscoveryTag.makeNonce()
        let mallory = RawPeer(hub, name: "Blake")
        let context = InviteContext(name: "Blake", nonce: nonce,
                                    tag: DiscoveryTag.make(identityKey: b.messenger.identityKey, nonce: nonce))
        mallory.transport.invite(a.token, context: context.encoded(), timeout: 5)
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
@Suite struct DemoWorldTests {
    @Test func demoWorldBehavesLikeRealPhones() async throws {
        let world = DemoWorld(scenario: .populated, latency: nil)
        let me = world.messenger
        me.start()
        let maya = try #require(me.contacts.first { $0.displayName == "Maya Okafor" })
        let jonas = try #require(me.contacts.first { $0.displayName == "Jonas Weber" })
        await waitUntil("Maya connects") { me.linkState(for: maya.id) == .connected }
        #expect(me.linkState(for: jonas.id) == .outOfRange)
        #expect(me.nearbyPeers.filter { $0.contactID == nil }.map(\.displayName).sorted() == ["Priya Raman", "Tomás"])

        me.send("Are you there?", to: maya.id)
        #expect(me.messages(for: maya.id).last?.status == .delivered)
        await waitUntil("Maya replies", timeout: .seconds(5)) { me.messages(for: maya.id).last?.direction == .incoming }

        world.setInRange(false, name: "Maya Okafor")
        #expect(me.linkState(for: maya.id) == .outOfRange)
        world.setInRange(true, name: "Maya Okafor")
        await waitUntil("Maya reconnects") { me.linkState(for: maya.id) == .connected }

        world.receiveRequest()
        await waitUntil("incoming request", timeout: .seconds(5)) { me.requests.contains { $0.direction == .incoming } }
    }
}
