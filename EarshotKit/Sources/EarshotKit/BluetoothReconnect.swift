@preconcurrency import CoreBluetooth
import Foundation

/// Decides when the Bluetooth layer reaches out again to a phone it has lost.
///
/// The idea: iOS keeps a `connect()` request open for as long as we like, at no cost, and
/// completes it the moment the other phone is in range again, even while both apps are in
/// the background. So for a phone we have really talked to, we never give up: when its
/// connection drops we ask iOS to connect again and simply leave that request waiting.
///
/// Which phones count: a Bluetooth address over which the engine opened a link (the
/// handshake started). The engine only links with saved contacts, or with a stranger
/// someone on this phone chose to connect to, so this is in practice "our contacts".
/// A phone stops counting when:
/// - the engine says so (`Transport.forget`: blocked, removed, everything erased);
/// - it came back, but the engine did not open a link over it within `unusedGrace`
///   (for example the contact was removed or blocked while out of range): see `isUnused`;
/// - we let go of it ourselves (a duplicate address of a phone we already hold, or to
///   free a slot): the `.dropped` ending.
///
/// Connections handed back by iOS after it relaunched the app carry no proof that a link
/// ever ran over them, so they are only *provisional*: chased like the others until they
/// come back once, but forgotten then unless a link opens, and never allowed to push a
/// confirmed phone out of the list.
///
/// Back-off: a connection that ends less than `stableAfter` after it came up counts as a
/// quick failure, and the next request waits `retryDelay` (4 s, doubling, at most 5 min).
/// A connection that stayed up that long resets the count. This keeps a phone that keeps
/// failing (flaky range edge, a broken peer) from waking both apps in a tight loop.
///
/// Nothing here is written to disk. The identifiers are random per app install and
/// say nothing about who the person is.
///
/// Example: Jensen and Tom are linked for an hour. Tom walks 200 m away, the connection
/// drops with `.linkLost`, and the decision is `.connect(after: 0)`: a request is left
/// waiting. Ten minutes later Tom walks back, iOS completes it, and the engine re-handshakes.
struct ReconnectPolicy {
    /// At most this many phones are remembered. Provisional ones go first, then the one
    /// linked longest ago.
    static let maxRemembered = 12
    static let firstRetryDelay: TimeInterval = 4
    static let maxRetryDelay: TimeInterval = 300
    /// A connection that stays up this long is healthy and resets the back-off.
    static let stableAfter: TimeInterval = 60
    /// A phone that came back but was not linked within this time is no longer chased.
    static let unusedGrace: TimeInterval = 120

    /// Why the Bluetooth connection to a phone ended.
    enum Ending: Equatable {
        /// The connection dropped, typically because the phones moved apart.
        case linkLost
        /// iOS reported that a connection attempt failed.
        case connectFailed
        /// Connected, but the Earshot service or beacon could not be read.
        case setupFailed
        /// The connection dropped and iOS is already reconnecting by itself
        /// (`CBConnectPeripheralOptionEnableAutoReconnect`).
        case systemReconnecting
        /// We let go on purpose (duplicate address, freeing a slot).
        case dropped
    }

    enum Decision: Equatable {
        /// Not a phone we chase: behave as before (it may be found again by scanning).
        case giveUp
        /// Ask iOS to connect after this many seconds and leave the request waiting.
        /// After `.systemReconnecting` this means: stop iOS's own reconnect first.
        case connect(after: TimeInterval)
        /// iOS is reconnecting already; only keep track of it.
        case waitForSystem
    }

    private struct Entry {
        var lastLinkUp: Date
        /// When the phone was last connected again and its beacon read.
        var cameBackAt: Date?
        /// Since when the current connection has been up (nil while it is down).
        var upSince: Date?
        /// Connections in a row that ended within `stableAfter`.
        var quickFailures = 0
        /// Restored after a relaunch, no link seen yet.
        var isProvisional = false
    }

    private var entries: [UUID: Entry] = [:]

    var remembered: [UUID] { Array(entries.keys) }

    func isRemembered(_ id: UUID) -> Bool { entries[id] != nil }

    func isProvisional(_ id: UUID) -> Bool { entries[id]?.isProvisional == true }

    func quickFailures(_ id: UUID) -> Int { entries[id]?.quickFailures ?? 0 }

    static func retryDelay(afterQuickFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(firstRetryDelay * pow(2, Double(min(failures, 30) - 1)), maxRetryDelay)
    }

    /// The engine opened a link over this address: it is confirmed. Returns an address
    /// that had to be forgotten to stay within `maxRemembered`, if any.
    @discardableResult
    mutating func linkUp(_ id: UUID, at now: Date = Date()) -> UUID? {
        var entry = entries[id] ?? Entry(lastLinkUp: now)
        entry.lastLinkUp = now
        entry.isProvisional = false
        // The back-off is reset by a connection that stays up, not by the link opening:
        // a peer that links and fails at once must not reset it every time.
        if entry.upSince == nil { entry.upSince = now }
        entries[id] = entry
        return evictIfNeeded(newcomer: id)
    }

    /// A connection handed back by iOS after a relaunch. Returns the address that had to
    /// be forgotten, which is `id` itself when only confirmed phones could make room.
    @discardableResult
    mutating func rememberProvisionally(_ id: UUID, at now: Date = Date()) -> UUID? {
        guard entries[id] == nil else { return nil }
        entries[id] = Entry(lastLinkUp: now, isProvisional: true)
        return evictIfNeeded(newcomer: id)
    }

    private mutating func evictIfNeeded(newcomer id: UUID) -> UUID? {
        guard entries.count > Self.maxRemembered else { return nil }
        let others = entries.filter { $0.key != id }
        let oldestProvisional = others.filter(\.value.isProvisional).min { $0.value.lastLinkUp < $1.value.lastLinkUp }?.key
        let victim: UUID?
        if let oldestProvisional {
            victim = oldestProvisional
        } else if entries[id]?.isProvisional == true {
            victim = id
        } else {
            victim = others.min { $0.value.lastLinkUp < $1.value.lastLinkUp }?.key
        }
        if let victim { entries[victim] = nil }
        return victim
    }

    mutating func forget(_ id: UUID) { entries[id] = nil }

    mutating func forgetAll() { entries.removeAll() }

    /// The connection is back and the beacon was read.
    mutating func cameBack(_ id: UUID, at now: Date = Date()) {
        entries[id]?.cameBackAt = now
        entries[id]?.upSince = now
    }

    /// True when the phone came back more than `unusedGrace` ago and no link was opened since.
    func isUnused(_ id: UUID, at now: Date = Date()) -> Bool {
        guard let entry = entries[id], let back = entry.cameBackAt, entry.lastLinkUp < back else { return false }
        return now.timeIntervalSince(back) >= Self.unusedGrace
    }

    mutating func decide(_ id: UUID, _ ending: Ending, at now: Date = Date()) -> Decision {
        guard var entry = entries[id] else { return .giveUp }
        if ending == .dropped {
            entries[id] = nil
            return .giveUp
        }
        let stayedUp = entry.upSince.map { now.timeIntervalSince($0) >= Self.stableAfter } ?? false
        entry.upSince = nil
        entry.quickFailures = stayedUp ? 0 : entry.quickFailures + 1
        entries[id] = entry
        if entry.quickFailures == 0 {
            return ending == .systemReconnecting ? .waitForSystem : .connect(after: 0)
        }
        return .connect(after: Self.retryDelay(afterQuickFailures: entry.quickFailures))
    }
}

/// Small decisions of `BluetoothTransport` that do not need a radio, kept apart so they
/// can be tested.
enum LinkTriage {
    enum DisconnectAction: Equatable {
        /// A drop already handled, or the expected end of a connection we cancelled.
        case ignore
        /// Clean up the link (the engine sees it end) and let the policy decide what next.
        case drop(ReconnectPolicy.Ending)
        /// iOS is reconnecting a phone we no longer want: stop that, then clean up.
        case cancelSystemReconnectAndDrop
    }

    /// What to do when Core Bluetooth reports that a connection ended. It may report the
    /// same drop through both "disconnected" callbacks, so the second is ignored.
    static func onDisconnect(cancelledRecently: Bool, alreadyWaiting: Bool,
                             remembered: Bool, isReconnecting: Bool) -> DisconnectAction {
        if cancelledRecently || alreadyWaiting { return .ignore }
        if isReconnecting { return remembered ? .drop(.systemReconnecting) : .cancelSystemReconnectAndDrop }
        return .drop(.linkLost)
    }

    enum RestoreAction: Equatable {
        /// Not ours to keep: cancel it.
        case cancel
        /// A request still waiting: keep it as the one request for that phone.
        case takeOver
        /// An open connection whose session died with the old process: close it and
        /// leave a fresh request waiting.
        case reopen
    }

    static func onRestore(_ state: CBPeripheralState, isRunning: Bool) -> RestoreAction {
        guard isRunning else { return .cancel }
        switch state {
        case .connecting: return .takeOver
        case .connected: return .reopen
        default: return .cancel
        }
    }

    /// Every remembered address of one phone: the one in use plus any earlier address that
    /// carried the same beacon nonce (iPhones change their Bluetooth address every few minutes).
    static func addresses(of primary: UUID?, nonce: Data?, nonceByAddress: [UUID: Data]) -> Set<UUID> {
        var result: Set<UUID> = primary.map { [$0] } ?? []
        if let nonce { result.formUnion(nonceByAddress.filter { $0.value == nonce }.keys) }
        return result
    }
}

// MARK: - Link diagnostics

/// One thing that happened on the Bluetooth link, for measuring range on real phones.
///
/// Kept in memory only (never written to disk, never sent anywhere). `peer` is a short
/// label taken from the random identifier iOS gives the other phone inside this app, not
/// the person's name or key.
public struct LinkEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A scan saw an Earshot phone (with the advertisement's signal strength).
        case discovered
        /// We asked iOS to connect.
        case connectRequested
        /// The Bluetooth connection is up (the engine link is not yet).
        case connected
        /// The engine opened a link (the handshake can start).
        case linkUp
        /// The engine link ended.
        case linkDown
        /// The Bluetooth connection ended.
        case disconnected
        /// A connection attempt or the setup after it failed.
        case connectFailed
        /// iOS is reconnecting by itself, or we left a connect request waiting for a phone
        /// that will come back.
        case reconnecting
        /// A signal-strength reading on an open connection.
        case signal
    }

    public enum AppState: String, Sendable {
        case foreground
        case background
    }

    public let date: Date
    public let kind: Kind
    /// First four hex digits of the other phone's per-app Bluetooth identifier.
    public let peer: String
    /// Signal strength in dBm, when known.
    public let rssi: Int?
    public let appState: AppState

    public init(date: Date, kind: Kind, peer: String, rssi: Int?, appState: AppState) {
        self.date = date
        self.kind = kind
        self.peer = peer
        self.rssi = rssi
        self.appState = appState
    }

    static func label(for id: UUID) -> String { String(id.uuidString.prefix(4)).lowercased() }

    /// One line, for logs and the command-line probe.
    public var summary: String {
        var text = "\(kind.rawValue) peer=\(peer)"
        if let rssi { text += " rssi=\(rssi)" }
        return text + " app=\(appState.rawValue)"
    }
}

/// The newest `capacity` link events, oldest first.
struct LinkEventLog {
    static let defaultCapacity = 500

    let capacity: Int
    private var storage: [LinkEvent] = []
    /// Where the next event goes once `storage` is full.
    private var next = 0

    init(capacity: Int = LinkEventLog.defaultCapacity) {
        self.capacity = max(capacity, 1)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func append(_ event: LinkEvent) {
        if storage.count < capacity {
            storage.append(event)
        } else {
            storage[next] = event
            next = (next + 1) % capacity
        }
    }

    var events: [LinkEvent] { Array(storage[next...] + storage[..<next]) }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        next = 0
    }
}

// MARK: - Outgoing queue limit

/// Counts the bytes waiting to go out to one phone, so a flood (for example a peer that
/// keeps asking for the same relayed mail) cannot grow the queue without bound.
///
/// Why 1 MiB: the largest burst honest use produces towards one phone is about 640 KB.
/// That is 60 waiting texts flushed at once on reconnect (the receiver's burst allowance)
/// at up to ~8 KB each (2,000 characters of non-Latin script), plus one relay round (~72 KB),
/// relay control messages (~60 KB) and one photo's pieces in flight (~19 KB). 1 MiB leaves
/// about 1.6× headroom, and 10 connected phones can hold at most ~10 MB in total.
struct OutgoingBudget: Equatable {
    static let limit = 1 << 20

    private(set) var bytes = 0

    /// Adds `count` bytes if they fit under the limit. Returns false, changing nothing, if not.
    mutating func admit(_ count: Int, limit: Int = OutgoingBudget.limit) -> Bool {
        guard bytes + count <= limit else { return false }
        bytes += count
        return true
    }

    /// Adds bytes that must go out whatever the limit (small control frames such as "close").
    mutating func force(_ count: Int) { bytes += count }

    mutating func sent(_ count: Int) { bytes = max(bytes - count, 0) }

    mutating func reset(to count: Int = 0) { bytes = count }

    /// How many chunks at the front of a queue must still go out so the other phone is not
    /// left holding half a frame. Each chunk starts with `0` ("more follows") or `1` ("last
    /// piece"). `midFrame` says whether the last chunk already sent was a "more follows" one.
    ///
    /// Example: sent so far ends with a `0` chunk; the queue is `[0, 1, 0, 1]`. The first two
    /// chunks finish that frame and are kept (returns 2); the next frame is dropped whole.
    static func chunksFinishingCurrentFrame(_ queue: [Data], midFrame: Bool) -> Int {
        guard midFrame else { return 0 }
        guard let end = queue.firstIndex(where: { $0.first == 1 }) else { return queue.count }
        return end + 1
    }
}
