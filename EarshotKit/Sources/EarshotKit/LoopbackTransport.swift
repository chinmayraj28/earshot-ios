import Foundation

/// A pretend radio environment that lives entirely in memory. Several
/// `LoopbackTransport`s attached to one hub behave like phones in the same room.
/// Used by the test suite and by demo mode; never by the real app.
@MainActor
public final class LoopbackHub {
    private struct Invite: Hashable { let from: PeerToken; let to: PeerToken }
    private struct Pair: Hashable {
        let a: PeerToken, b: PeerToken
        init(_ x: PeerToken, _ y: PeerToken) {
            (a, b) = x.rawValue < y.rawValue ? (x, y) : (y, x)
        }
        func contains(_ t: PeerToken) -> Bool { a == t || b == t }
        func other(than t: PeerToken) -> PeerToken { a == t ? b : a }
    }

    private var nodes: [PeerToken: LoopbackTransport] = [:]
    private var invites: Set<Invite> = []
    private var connections: Set<Pair> = []
    private typealias Job = @MainActor @Sendable () -> Void
    private var queue: [Job] = []
    private var isDraining = false
    private let latency: Duration?
    private var delayed: AsyncStream<Job>.Continuation?

    /// Lets a test inspect, change or drop (return nil) any frame in flight.
    public var intercept: ((_ data: Data, _ from: PeerToken, _ to: PeerToken) -> Data?)?

    /// - Parameter latency: when set, every event is delivered after this delay, in order.
    public init(latency: Duration? = nil) {
        self.latency = latency
        if let latency {
            let (stream, continuation) = AsyncStream<Job>.makeStream()
            delayed = continuation
            Task { @MainActor in
                for await job in stream {
                    try? await Task.sleep(for: latency)
                    job()
                }
            }
        }
    }

    public func makeTransport(token: String = UUID().uuidString) -> LoopbackTransport {
        let transport = LoopbackTransport(hub: self, token: PeerToken(rawValue: token))
        nodes[transport.token] = transport
        return transport
    }

    private func emit(_ event: TransportEvent, to token: PeerToken) {
        let job: Job = { [weak self] in self?.nodes[token]?.eventHandler?(event) }
        if let delayed {
            delayed.yield(job)
            return
        }
        queue.append(job)
        atomically {}
    }

    /// Runs `body`, then delivers every event it produced, in order. Events raised
    /// while delivering are appended to the same queue rather than nested.
    private func atomically(_ body: () -> Void) {
        guard !isDraining else { return body() }
        isDraining = true
        body()
        while !queue.isEmpty { queue.removeFirst()() }
        isDraining = false
    }

    private func isOnAir(_ token: PeerToken) -> Bool {
        guard let node = nodes[token] else { return false }
        return node.advertisement != nil && node.isReachable
    }

    private func announce(_ node: LoopbackTransport) {
        guard let own = node.advertisement, node.isReachable else { return }
        for other in nodes.values where other.token != node.token && isOnAir(other.token) {
            if own.isVisible { emit(.found(node.token, own), to: other.token) }
            if let theirs = other.advertisement, theirs.isVisible { emit(.found(other.token, theirs), to: node.token) }
        }
    }

    private func withdraw(_ node: LoopbackTransport, notifySelf: Bool) {
        let token = node.token
        for other in nodes.values where other.token != token && isOnAir(other.token) {
            if node.advertisement?.isVisible == true { emit(.lost(token), to: other.token) }
            if notifySelf, other.advertisement?.isVisible == true { emit(.lost(other.token), to: token) }
        }
        for pair in connections where pair.contains(token) {
            connections.remove(pair)
            emit(.disconnected(token), to: pair.other(than: token))
            if notifySelf { emit(.disconnected(pair.other(than: token)), to: token) }
        }
        for invite in invites where invite.from == token || invite.to == token {
            invites.remove(invite)
            if invite.to == token { emit(.disconnected(token), to: invite.from) }
            if invite.from == token, notifySelf { emit(.disconnected(invite.to), to: token) }
        }
    }

    // Called by transports

    fileprivate func started(_ node: LoopbackTransport) { atomically { announce(node) } }
    fileprivate func stopping(_ node: LoopbackTransport) { atomically { withdraw(node, notifySelf: false) } }

    fileprivate func invite(from: PeerToken, to: PeerToken, context: Data) {
        guard isOnAir(from), isOnAir(to), nodes[to]?.advertisement?.isVisible == true else {
            emit(.disconnected(to), to: from)
            return
        }
        invites.insert(Invite(from: from, to: to))
        emit(.invited(by: from, context: context), to: to)
    }

    fileprivate func respond(_ node: PeerToken, to inviter: PeerToken, accept: Bool) {
        guard invites.remove(Invite(from: inviter, to: node)) != nil else { return }
        if accept {
            invites.remove(Invite(from: node, to: inviter))
            connections.insert(Pair(node, inviter))
            atomically {
                emit(.connected(node), to: inviter)
                emit(.connected(inviter), to: node)
            }
        } else {
            emit(.disconnected(node), to: inviter)
        }
    }

    fileprivate func send(_ data: Data, from: PeerToken, to: PeerToken) throws {
        guard connections.contains(Pair(from, to)) else { throw TransportError.notConnected }
        var data = data
        if let intercept {
            guard let changed = intercept(data, from, to) else { return }
            data = changed
        }
        emit(.received(data, from: from), to: to)
    }

    fileprivate func disconnect(_ node: PeerToken, from peer: PeerToken) {
        invites.remove(Invite(from: node, to: peer))
        if connections.remove(Pair(node, peer)) != nil {
            emit(.disconnected(node), to: peer)
        }
    }

    // Test and demo controls

    /// Simulates a phone walking out of range (false) or back in (true).
    public func setReachable(_ reachable: Bool, _ node: LoopbackTransport) {
        guard node.isReachable != reachable else { return }
        atomically {
            if reachable {
                node.isReachable = true
                announce(node)
            } else {
                withdraw(node, notifySelf: true)
                node.isReachable = false
            }
        }
    }

    /// Simulates a link dropping while both phones stay in range.
    public func dropConnection(_ a: LoopbackTransport, _ b: LoopbackTransport) {
        guard connections.remove(Pair(a.token, b.token)) != nil else { return }
        atomically {
            emit(.disconnected(b.token), to: a.token)
            emit(.disconnected(a.token), to: b.token)
        }
    }

    /// Simulates every unanswered request timing out.
    public func expireInvites() {
        atomically {
            for invite in invites {
                invites.remove(invite)
                emit(.disconnected(invite.to), to: invite.from)
            }
        }
    }
}

@MainActor
public final class LoopbackTransport: Transport {
    public let token: PeerToken
    public var eventHandler: ((TransportEvent) -> Void)?
    fileprivate(set) var advertisement: LocalAdvertisement?
    fileprivate(set) var isReachable = true
    private weak var hub: LoopbackHub?

    fileprivate init(hub: LoopbackHub, token: PeerToken) {
        self.hub = hub
        self.token = token
    }

    public func start(_ advertisement: LocalAdvertisement) {
        self.advertisement = advertisement
        hub?.started(self)
    }

    public func stop() {
        hub?.stopping(self)
        advertisement = nil
    }

    public func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {
        hub?.invite(from: token, to: peer, context: context)
    }

    public func respondToInvitation(from peer: PeerToken, accept: Bool) {
        hub?.respond(token, to: peer, accept: accept)
    }

    public func send(_ data: Data, to peer: PeerToken) throws {
        guard let hub else { throw TransportError.notConnected }
        try hub.send(data, from: token, to: peer)
    }

    public func disconnect(_ peer: PeerToken) {
        hub?.disconnect(token, from: peer)
    }
}
