import Foundation

/// What a phone announces to others nearby.
public struct LocalAdvertisement: Sendable, Equatable {
    public var displayName: String
    public var nonce: Data
    public var tag: Data
    /// When false the phone only listens; it does not announce itself.
    public var isVisible: Bool

    public init(displayName: String, nonce: Data, tag: Data, isVisible: Bool) {
        self.displayName = displayName
        self.nonce = nonce
        self.tag = tag
        self.isVisible = isVisible
    }
}

public enum TransportEvent: Sendable {
    case found(PeerToken, LocalAdvertisement)
    case lost(PeerToken)
    case invited(by: PeerToken, context: Data)
    case connected(PeerToken)
    /// The link to this peer ended, or an invitation to it was declined or timed out.
    case disconnected(PeerToken)
    case received(Data, from: PeerToken)
    case unavailable(TransportProblem)
    /// The radios are usable (again), e.g. after Local Network access was granted.
    case ready
}

/// The radio layer: finds nearby devices and moves opaque bytes between two of them.
/// It knows nothing about identities, encryption or messages.
@MainActor
public protocol Transport: AnyObject {
    var eventHandler: ((TransportEvent) -> Void)? { get set }
    func start(_ advertisement: LocalAdvertisement)
    func stop()
    func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval)
    func respondToInvitation(from peer: PeerToken, accept: Bool)
    func send(_ data: Data, to peer: PeerToken) throws
    /// Closes the link locally. Does not produce a `.disconnected` event on this side.
    /// The radio may still reconnect to this phone later by itself; use `forget` to stop that.
    func disconnect(_ peer: PeerToken)
    /// Stops reconnecting to this phone by itself (for example when it is blocked or its
    /// contact removed). Does not close a link; call `disconnect` for that.
    func forget(_ peer: PeerToken)
    /// Forgets every phone the radio would reconnect to by itself (when everything is erased).
    func forgetAllPeers()
}

extension Transport {
    /// Radios that never reconnect by themselves have nothing to forget.
    public func forget(_ peer: PeerToken) {}
    public func forgetAllPeers() {}
}

public enum TransportError: Error {
    case notConnected
}
