import Foundation
import os

/// Where photo files live. Each photo is one file, named after its message
/// (for example `6F9619FF-8B86-D011-B42D-00C04FC964FF.jpg`), next to the conversations.
///
/// Files get the same treatment as the rest of Earshot's data (`FilePersistence`):
/// encrypted by iOS until the phone has been unlocked once after a restart, and left out
/// of iCloud and computer backups. Photos never leave the two phones.
///
/// A photo that is still arriving is written piece by piece to `<name>.partial`, so a
/// 1 MB photo never sits in memory several times over, and it only gets its real name
/// once it has been checked. Anything left as `.partial` (for example after a crash
/// mid-transfer) is deleted the next time Earshot starts (`removeAll(except:)`).
public final class AttachmentStore: @unchecked Sendable {
    private enum Backend {
        case directory(URL)
        case memory
    }

    private let backend: Backend
    private let lock = NSLock()
    /// In-memory mode only.
    private var files: [String: Data] = [:]
    private static let log = Logger(subsystem: "app.earshot", category: "storage")

    /// Files in a folder on disk. Used by the real app.
    public init(directory: URL) { backend = .directory(directory) }

    /// Keeps everything in memory. Used by tests and demo mode.
    public init() { backend = .memory }

    /// The real app's folder: `Application Support/Earshot/attachments`.
    public static func defaultDirectory() -> URL {
        FilePersistence.defaultDirectory().appendingPathComponent("attachments", isDirectory: true)
    }

    enum StoreError: Error {
        case badName
    }

    /// Only names Earshot makes itself are allowed, so nothing can point outside the folder.
    static func isValidName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg"), name.count <= 64 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            && !name.contains("..")
    }

    public static func fileName(for messageID: UUID) -> String { "\(messageID.uuidString).jpg" }

    // MARK: Finished files

    /// Saves a finished file under `name`, replacing any file of that name.
    public func save(_ data: Data, as name: String) throws {
        guard Self.isValidName(name) else { throw StoreError.badName }
        switch backend {
        case .memory:
            lock.withLock { files[name] = data }
        case .directory(let directory):
            try prepare(directory)
            try data.write(to: directory.appendingPathComponent(name), options: Self.writeOptions)
        }
    }

    public func data(named name: String) -> Data? {
        guard Self.isValidName(name) else { return nil }
        switch backend {
        case .memory: return lock.withLock { files[name] }
        case .directory(let directory): return try? Data(contentsOf: directory.appendingPathComponent(name))
        }
    }

    /// A file address for viewers and the share sheet. Nil in memory mode.
    public func url(named name: String) -> URL? {
        guard Self.isValidName(name), case .directory(let directory) = backend else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func delete(named name: String) {
        guard Self.isValidName(name) else { return }
        switch backend {
        case .memory: lock.withLock { files[name] = nil }
        case .directory(let directory): try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func deleteAll() {
        switch backend {
        case .memory: lock.withLock { files.removeAll() }
        case .directory(let directory): try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes every file whose name is not in `keep`, including half-received ones.
    /// Called at launch with the names that saved messages still point to.
    public func removeAll(except keep: Set<String>) {
        switch backend {
        case .memory:
            lock.withLock { files = files.filter { keep.contains($0.key) } }
        case .directory(let directory):
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where !keep.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Every file name currently stored (finished and half-received). For tests.
    public func allNames() -> Set<String> {
        switch backend {
        case .memory: return lock.withLock { Set(files.keys) }
        case .directory(let directory):
            return Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        }
    }

    /// Bytes used by stored files. Checked against the storage quota before a photo is accepted.
    public func usedBytes() -> Int {
        switch backend {
        case .memory:
            return lock.withLock { files.values.reduce(0) { $0 + $1.count } }
        case .directory(let directory):
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.reduce(0) { total, name in
                let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]) as? Int
                return total + (size ?? 0)
            }
        }
    }

    // MARK: Receiving piece by piece

    /// Starts a file that arrives in pieces. Nothing is visible under `name` until `commit()`.
    @MainActor
    func beginIncoming(as name: String) throws -> IncomingFile {
        guard Self.isValidName(name) else { throw StoreError.badName }
        switch backend {
        case .memory:
            return IncomingFile(store: self, name: name, handle: nil, partialURL: nil)
        case .directory(let directory):
            try prepare(directory)
            let partial = directory.appendingPathComponent(name + ".partial")
            try? FileManager.default.removeItem(at: partial)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: Self.fileAttributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: partial)
            return IncomingFile(store: self, name: name, handle: handle, partialURL: partial)
        }
    }

    fileprivate func commitIncoming(name: String, partialURL: URL?, buffer: Data) throws {
        switch backend {
        case .memory:
            lock.withLock { files[name] = buffer }
        case .directory(let directory):
            guard let partialURL else { throw CocoaError(.fileNoSuchFile) }
            let target = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partialURL, to: target)
        }
    }

    // MARK: Disk details

    private func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: Self.fileAttributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private static var fileAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }
}

/// A photo that is still arriving. Pieces go straight to disk; `commit()` gives the file
/// its real name, `discard()` deletes it. Used on the main actor only.
@MainActor
final class IncomingFile {
    private let store: AttachmentStore
    let name: String
    private var handle: FileHandle?
    private let partialURL: URL?
    /// In-memory mode only.
    private var buffer = Data()
    private(set) var isClosed = false

    fileprivate init(store: AttachmentStore, name: String, handle: FileHandle?, partialURL: URL?) {
        self.store = store
        self.name = name
        self.handle = handle
        self.partialURL = partialURL
    }

    func append(_ data: Data) throws {
        guard !isClosed else { throw CocoaError(.fileWriteUnknown) }
        if let handle { try handle.write(contentsOf: data) } else { buffer.append(data) }
    }

    /// Stops writing. What was written can then be checked with `source`.
    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    /// The received bytes, for checking before they are accepted: a file on disk, or the in-memory buffer.
    var source: PhotoSource {
        if let partialURL { return .file(partialURL) }
        return .data(buffer)
    }

    func commit() throws {
        try close()
        try store.commitIncoming(name: name, partialURL: partialURL, buffer: buffer)
        buffer = Data()
    }

    func discard() {
        try? handle?.close()
        handle = nil
        isClosed = true
        buffer = Data()
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
    }
}

/// Bytes of an image, either already in memory or in a file.
public enum PhotoSource: Sendable {
    case data(Data)
    case file(URL)
}
