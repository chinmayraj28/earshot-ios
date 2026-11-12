import Foundation
import os
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
    /// `completion` is called with true once the conversation is safely stored, false if
    /// storing failed. It may be called on any thread.
    func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?)
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
    public func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?) {
        lock.withLock { state.conversations[id] = conversation }
        completion?(true)
    }
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

    private struct PendingWrite {
        var encode: @Sendable () -> Data?
        var completions: [@Sendable (Bool) -> Void]
    }

    private let lock = NSLock()
    private var pending: [URL: PendingWrite] = [:]
    private static let log = Logger(subsystem: "app.earshot", category: "storage")

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        // Unreadable while the phone is locked. Earshot only runs in the foreground.
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    /// Queues a write. If one for the same file is already waiting, the newer value
    /// replaces it, so a burst of changes results in a single write of the latest state.
    private func write<T: Encodable & Sendable>(_ value: T, to url: URL, completion: (@Sendable (Bool) -> Void)? = nil) {
        let alreadyQueued = lock.withLock { () -> Bool in
            let existing = pending[url]
            var completions = existing?.completions ?? []
            if let completion { completions.append(completion) }
            pending[url] = PendingWrite(encode: { try? JSONEncoder().encode(value) }, completions: completions)
            return existing != nil
        }
        guard !alreadyQueued else { return }
        queue.async { [self] in
            guard let job = lock.withLock({ pending.removeValue(forKey: url) }) else { return }
            prepareDirectory()
            var stored = false
            if let data = job.encode() {
                do {
                    try data.write(to: url, options: Self.writeOptions)
                    stored = true
                } catch {
                    Self.log.error("Could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            job.completions.forEach { $0(stored) }
        }
    }

    private func cancelPending(_ matches: (URL) -> Bool) {
        let cancelled = lock.withLock { () -> [PendingWrite] in
            let urls = pending.keys.filter(matches)
            return urls.compactMap { pending.removeValue(forKey: $0) }
        }
        cancelled.forEach { job in job.completions.forEach { $0(false) } }
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
    public func save(conversation: Conversation, for id: ContactID, completion: (@Sendable (Bool) -> Void)?) {
        write(conversation, to: conversationURL(id), completion: completion)
    }

    public func deleteConversation(for id: ContactID) {
        let url = conversationURL(id)
        cancelPending { $0 == url }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    public func eraseAll() {
        cancelPending { _ in true }
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }

    public func flush() { queue.sync {} }
}

public protocol IdentityStore: Sendable {
    /// Returns nil only when no key has ever been stored. Throws when the store
    /// cannot be read right now, so a temporary failure is never mistaken for "no key".
    func load() throws -> Data?
    func save(_ key: Data) throws
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

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
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

    public func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ key: Data) throws {
        // Update in place when a key exists, so a failure never leaves the Keychain empty.
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = key
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() { SecItemDelete(baseQuery as CFDictionary) }
}
