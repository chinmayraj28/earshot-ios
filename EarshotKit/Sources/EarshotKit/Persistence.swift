import Foundation
import Security

public struct PersistedState: Sendable {
    public var profile: Profile
    public var contacts: [Contact]
    public var conversations: [ContactID: Conversation]

    public init(profile: Profile = Profile(), contacts: [Contact] = [], conversations: [ContactID: Conversation] = [:]) {
        self.profile = profile
        self.contacts = contacts
        self.conversations = conversations
    }
}

public protocol Persistence: Sendable {
    func load() -> PersistedState
    func save(profile: Profile)
    func save(contacts: [Contact])
    func save(conversation: Conversation, for id: ContactID)
    func deleteConversation(for id: ContactID)
    func eraseAll()
    /// Blocks until every queued write has reached the disk.
    func flush()
}

/// Keeps everything in memory. Used by tests and by demo mode.
public final class InMemoryPersistence: Persistence, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedState

    public init(_ state: PersistedState = PersistedState()) { self.state = state }

    public func load() -> PersistedState { lock.withLock { state } }
    public func save(profile: Profile) { lock.withLock { state.profile = profile } }
    public func save(contacts: [Contact]) { lock.withLock { state.contacts = contacts } }
    public func save(conversation: Conversation, for id: ContactID) { lock.withLock { state.conversations[id] = conversation } }
    public func deleteConversation(for id: ContactID) { lock.withLock { state.conversations[id] = nil } }
    public func eraseAll() { lock.withLock { state = PersistedState() } }
    public func flush() {}
}

/// Stores the profile, contacts and each conversation as JSON files inside the app's
/// own container. Files are encrypted by iOS while the phone is locked and are
/// excluded from iCloud and computer backups, so messages never leave the device.
public final class FilePersistence: Persistence, @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "earshot.persistence", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Earshot", isDirectory: true)
    }

    private var profileURL: URL { directory.appendingPathComponent("profile.json") }
    private var contactsURL: URL { directory.appendingPathComponent("contacts.json") }
    private var conversationsURL: URL { directory.appendingPathComponent("conversations", isDirectory: true) }
    private func conversationURL(_ id: ContactID) -> URL {
        conversationsURL.appendingPathComponent("\(id.rawValue).json")
    }

    private func prepareDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Keep the unreadable file for diagnosis instead of silently overwriting it.
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    private func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async { [self] in
            prepareDirectory()
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    public func load() -> PersistedState {
        queue.sync {
            var state = PersistedState()
            state.profile = read(Profile.self, from: profileURL) ?? Profile()
            state.contacts = read([Contact].self, from: contactsURL) ?? []
            for contact in state.contacts {
                state.conversations[contact.id] = read(Conversation.self, from: conversationURL(contact.id)) ?? Conversation()
            }
            return state
        }
    }

    public func save(profile: Profile) { write(profile, to: profileURL) }
    public func save(contacts: [Contact]) { write(contacts, to: contactsURL) }
    public func save(conversation: Conversation, for id: ContactID) { write(conversation, to: conversationURL(id)) }

    public func deleteConversation(for id: ContactID) {
        let url = conversationURL(id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    public func eraseAll() {
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }

    public func flush() { queue.sync {} }
}

public protocol IdentityStore: Sendable {
    func load() -> Data?
    func save(_ key: Data)
    func delete()
}

public final class InMemoryIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    public init(_ key: Data? = nil) { self.key = key }
    public func load() -> Data? { lock.withLock { key } }
    public func save(_ key: Data) { lock.withLock { self.key = key } }
    public func delete() { lock.withLock { key = nil } }
}

/// Keeps the identity key in the Keychain, readable only on this device.
public struct KeychainIdentityStore: IdentityStore {
    private let service: String
    private let account = "identity-v1"

    public init(service: String = "app.earshot.identity") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(_ key: Data) {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func delete() { SecItemDelete(baseQuery as CFDictionary) }
}
