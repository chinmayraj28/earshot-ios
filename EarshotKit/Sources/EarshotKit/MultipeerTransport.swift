import Foundation
@preconcurrency import MultipeerConnectivity
import Network

/// The real radio layer, built on Apple's MultipeerConnectivity framework.
///
/// What the platform gives us, and what it does not:
/// - Discovery and data travel over peer-to-peer Wi-Fi and Bluetooth. No router,
///   internet connection or cellular service is involved, but both radios must be switched on.
/// - It only runs while the app is in the foreground. iOS stops advertising, browsing
///   and open sessions shortly after an app is backgrounded. That is why the app on a
///   real iPhone uses `BluetoothTransport` instead; this transport remains for the
///   iOS Simulator (which has no Bluetooth) and for Mac-to-Mac testing.
/// - Range is that of the phone's own radios: people in the same room or close by.
/// - iOS asks the user for Local Network access the first time `start` is called.
///
/// Each remote phone gets its own `MCSession`, so two of your contacts never learn
/// that the other one is connected to you.
@MainActor
public final class MultipeerTransport: NSObject, Transport {
    /// Bonjour service name. Must match `NSBonjourServices` in the app's Info.plist.
    public static let serviceType = "earshot-msg"

    public var eventHandler: ((TransportEvent) -> Void)?

    private var localPeer: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var permissionProbe: NWBrowser?
    private var peers: [PeerToken: MCPeerID] = [:]
    private var tokens: [MCPeerID: PeerToken] = [:]
    private var tokenCounter = 0
    private var sessions: [PeerToken: MCSession] = [:]
    private var invitationHandlers: [PeerToken: (Bool, MCSession?) -> Void] = [:]

    public override init() { super.init() }

    public func start(_ advertisement: LocalAdvertisement) {
        stop()
        // The system-level peer name is a random handle, not the person's name or device name.
        let peer = MCPeerID(displayName: "es-" + UUID().uuidString.prefix(8).lowercased())
        localPeer = peer

        if advertisement.isVisible {
            let info = [
                "v": "1",
                "n": advertisement.displayName,
                "k": advertisement.nonce.base64EncodedString(),
                "t": advertisement.tag.base64EncodedString(),
            ]
            let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: info, serviceType: Self.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        }

        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        startPermissionProbe()
    }

    public func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        permissionProbe?.cancel()
        permissionProbe = nil
        for handler in invitationHandlers.values { handler(false, nil) }
        invitationHandlers.removeAll()
        for session in sessions.values {
            session.delegate = nil
            session.disconnect()
        }
        sessions.removeAll()
        peers.removeAll()
        tokens.removeAll()
        localPeer = nil
    }

    public func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {
        guard let browser, let peerID = peers[peer], let session = makeSession() else {
            DispatchQueue.main.async { [weak self] in self?.eventHandler?(.disconnected(peer)) }
            return
        }
        replaceSession(for: peer, with: session)
        browser.invitePeer(peerID, to: session, withContext: context, timeout: timeout)
    }

    public func respondToInvitation(from peer: PeerToken, accept: Bool) {
        guard let handler = invitationHandlers.removeValue(forKey: peer) else { return }
        guard accept, let session = makeSession() else {
            handler(false, nil)
            return
        }
        replaceSession(for: peer, with: session)
        handler(true, session)
    }

    public func send(_ data: Data, to peer: PeerToken) throws {
        guard let session = sessions[peer], let peerID = peers[peer], session.connectedPeers.contains(peerID) else {
            throw TransportError.notConnected
        }
        try session.send(data, toPeers: [peerID], with: .reliable)
    }

    public func disconnect(_ peer: PeerToken) {
        replaceSession(for: peer, with: nil)
    }

    /// Gives each remote device its own handle. The handle is tied to the framework's
    /// peer object, not to the name it broadcasts, so a second device announcing the
    /// same name cannot take over an existing peer's slot.
    fileprivate func token(for peerID: MCPeerID) -> PeerToken {
        if let token = tokens[peerID] { return token }
        tokenCounter += 1
        let token = PeerToken(rawValue: "\(peerID.displayName)#\(tokenCounter)")
        tokens[peerID] = token
        peers[token] = peerID
        return token
    }

    fileprivate func knownToken(for peerID: MCPeerID) -> PeerToken? { tokens[peerID] }

    private func makeSession() -> MCSession? {
        guard let localPeer else { return nil }
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// Swaps in a new session for a peer. The old one is silenced first, so its
    /// closing does not look like the new link dropping.
    private func replaceSession(for peer: PeerToken, with session: MCSession?) {
        if let old = sessions[peer] {
            old.delegate = nil
            old.disconnect()
        }
        sessions[peer] = session
    }

    /// MultipeerConnectivity does not report a denied Local Network permission, so a
    /// plain Bonjour browse for the same service is used to detect it.
    private func startPermissionProbe() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let probe = NWBrowser(for: .bonjour(type: "_\(Self.serviceType)._tcp", domain: nil), using: parameters)
        probe.stateUpdateHandler = { [weak self] state in
            let policyDenied: Int32 = -65570 // kDNSServiceErr_PolicyDenied
            let event: TransportEvent
            switch state {
            case .waiting(.dns(let code)) where code == policyDenied: event = .unavailable(.localNetworkDenied)
            case .ready: event = .ready
            default: return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.eventHandler?(event) }
            }
        }
        probe.start(queue: .main)
        permissionProbe = probe
    }

    fileprivate func emit(_ event: TransportEvent) { eventHandler?(event) }
}

/// Carries framework objects from MultipeerConnectivity's callback queue to the main actor.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                                    withDiscoveryInfo info: [String: String]?) {
        guard let info, info["v"] == "1", let name = info["n"],
              let nonce = info["k"].flatMap({ Data(base64Encoded: $0) }),
              let tag = info["t"].flatMap({ Data(base64Encoded: $0) }) else { return }
        let browser = Unchecked(value: browser), peerID = Unchecked(value: peerID)
        onMain { [weak self] in
            guard let self, self.browser === browser.value else { return }
            let token = self.token(for: peerID.value)
            self.emit(.found(token, LocalAdvertisement(displayName: name, nonce: nonce, tag: tag, isVisible: true)))
        }
    }

    public nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let browser = Unchecked(value: browser), peerID = Unchecked(value: peerID)
        onMain { [weak self] in
            guard let self, self.browser === browser.value, let token = self.knownToken(for: peerID.value) else { return }
            if self.sessions[token] == nil, self.invitationHandlers[token] == nil {
                self.peers[token] = nil
                self.tokens[peerID.value] = nil
            }
            self.emit(.lost(token))
        }
    }

    public nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let message = error.localizedDescription
        onMain { [weak self] in self?.emit(.unavailable(.failedToStart(message))) }
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                       didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                       invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let advertiser = Unchecked(value: advertiser), peerID = Unchecked(value: peerID)
        let handler = Unchecked(value: invitationHandler)
        onMain { [weak self] in
            guard let self, self.advertiser === advertiser.value else {
                handler.value(false, nil)
                return
            }
            let token = self.token(for: peerID.value)
            self.invitationHandlers.removeValue(forKey: token)?(false, nil)
            self.invitationHandlers[token] = handler.value
            self.emit(.invited(by: token, context: context ?? Data()))
        }
    }

    public nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let message = error.localizedDescription
        onMain { [weak self] in self?.emit(.unavailable(.failedToStart(message))) }
    }
}

extension MultipeerTransport: MCSessionDelegate {
    public nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let session = Unchecked(value: session), peerID = Unchecked(value: peerID)
        onMain { [weak self] in
            guard let self, let token = self.knownToken(for: peerID.value),
                  self.sessions[token] === session.value else { return }
            switch state {
            case .connected:
                self.emit(.connected(token))
            case .notConnected:
                session.value.delegate = nil
                self.sessions[token] = nil
                self.emit(.disconnected(token))
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    public nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let session = Unchecked(value: session), peerID = Unchecked(value: peerID)
        onMain { [weak self] in
            guard let self, let token = self.knownToken(for: peerID.value),
                  self.sessions[token] === session.value else { return }
            self.emit(.received(data, from: token))
        }
    }

    // Earshot only exchanges small data frames; streams and file transfers are unused.
    public nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                                    withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    public nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                                    fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    public nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                                    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
    }
}
