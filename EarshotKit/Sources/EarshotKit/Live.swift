import Foundation

/// Which radio layer to use.
public enum Radio: Sendable {
    /// Bluetooth LE. Works in the background on a real iPhone.
    case bluetooth
    /// Apple's MultipeerConnectivity (Wi-Fi + Bluetooth). Foreground only.
    case multipeer

    /// Bluetooth everywhere except the iOS Simulator, which has no Bluetooth radio.
    public static var standard: Radio {
        #if targetEnvironment(simulator)
        .multipeer
        #else
        .bluetooth
        #endif
    }

    @MainActor
    func makeTransport() -> Transport {
        switch self {
        case .bluetooth: BluetoothTransport()
        case .multipeer: MultipeerTransport()
        }
    }
}

extension Messenger {
    /// The messenger used by the real app: real radios, files on disk, key in the Keychain.
    public static func live(radio: Radio = .standard) -> Messenger {
        Messenger(transport: radio.makeTransport(),
                  persistence: FilePersistence(directory: FilePersistence.defaultDirectory()),
                  identityStore: KeychainIdentityStore(),
                  attachments: AttachmentStore(directory: AttachmentStore.defaultDirectory()))
    }

    /// Real radios, but nothing is saved. Used by end-to-end tests so every run starts clean.
    public static func ephemeral(radio: Radio = .standard) -> Messenger {
        Messenger(transport: radio.makeTransport(), persistence: InMemoryPersistence(),
                  identityStore: InMemoryIdentityStore())
    }
}
