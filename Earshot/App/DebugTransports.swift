#if DEBUG
import EarshotKit
import Foundation

/// Debug builds only: a radio that reports Bluetooth access as denied as soon as it starts,
/// so the "permission denied" state can be seen and screenshotted in the Simulator
/// (`-simulateBluetoothDenied`). Never compiled into release builds.
@MainActor
final class DeniedTransport: Transport {
    var eventHandler: ((TransportEvent) -> Void)?

    func start(_ advertisement: LocalAdvertisement) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.eventHandler?(.unavailable(.bluetoothDenied))
        }
    }

    func stop() {}
    func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {}
    func respondToInvitation(from peer: PeerToken, accept: Bool) {}
    func send(_ data: Data, to peer: PeerToken) throws { throw TransportError.notConnected }
    func disconnect(_ peer: PeerToken) {}

    static func messenger() -> Messenger {
        let state = PersistedState(profile: Profile(displayName: "Alex", isVisible: true, hasCompletedOnboarding: true))
        return Messenger(transport: DeniedTransport(), persistence: InMemoryPersistence(state),
                         identityStore: InMemoryIdentityStore())
    }
}
#endif
