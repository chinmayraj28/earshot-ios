@preconcurrency import CoreBluetooth
import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// The radio layer used on real iPhones, built on Bluetooth Low Energy (Core Bluetooth).
///
/// Bluetooth LE is the one phone-to-phone radio that iOS lets an app keep using while
/// it is in the background, which is what makes "a message reaches a phone that is
/// locked in a pocket" possible. What the platform gives us, and what it does not:
///
/// - Range is Bluetooth range: the same room, or a few tens of metres in the open.
/// - While the app is in the background iOS still announces it and still wakes it for
///   incoming connections and data, but more slowly, and a backgrounded app can only be
///   found by a phone that is actively looking for Earshot. In practice: one of the two
///   people needs Earshot open for two phones to find each other; once they are linked,
///   the link survives both apps going to the background while the phones stay in range.
/// - If the person swipes the app away, or restarts the phone, nothing runs until they
///   open Earshot again.
/// - A phone we have linked with is never given up on: when its connection drops we ask
///   iOS to connect again and leave that request waiting, with no time limit. iOS completes
///   it whenever the two phones are back in range, even with both apps in the background
///   (see `ReconnectPolicy`). Phones we only saw nearby still get one short attempt.
///
/// How the link works: every phone both announces a small service ("peripheral" role)
/// and looks for that service on others ("central" role). The side that connects reads
/// the other side's beacon (name, nonce, tag) and may then send an invitation. All bytes
/// flow over that one connection: writes one way, notifications the other.
@MainActor
public final class BluetoothTransport: NSObject, Transport {
    public static let serviceID = CBUUID(string: "8E5C0001-6F1A-4C3B-9D2E-EA25407A11E0")
    static let beaconID = CBUUID(string: "8E5C0002-6F1A-4C3B-9D2E-EA25407A11E0")
    /// Written by the connecting phone.
    static let inboxID = CBUUID(string: "8E5C0003-6F1A-4C3B-9D2E-EA25407A11E0")
    /// Notified to the connecting phone.
    static let outboxID = CBUUID(string: "8E5C0004-6F1A-4C3B-9D2E-EA25407A11E0")

    /// How many nearby phones are kept connected at the Bluetooth level at once.
    static let maxPeripherals = 10
    static let connectTimeout: TimeInterval = 20
    static let rescanInterval: TimeInterval = 30
    static let failurePause: TimeInterval = 60
    static let duplicatePause: TimeInterval = 600
    /// How often the signal strength of linked phones is read while the app is on screen.
    static let signalInterval: TimeInterval = 10

    public var eventHandler: ((TransportEvent) -> Void)?

    private enum Route {
        /// We made the Bluetooth connection: we write, they notify.
        case asCentral
        /// They made the Bluetooth connection: they write, we notify.
        case asPeripheral
    }

    /// Everything known about one nearby phone.
    private final class Remote {
        let token: PeerToken
        var nonce: Data?

        // Our connection to them.
        var peripheral: CBPeripheral?
        var inbox: CBCharacteristic?
        var writeQueue: [Data] = []
        var isWriting = false
        /// Bytes in `writeQueue` (see `OutgoingBudget`).
        var queued = OutgoingBudget()
        /// The last chunk written was a "more follows" one.
        var writeMidFrame = false
        var fromPeripheral = BluetoothWire.Reassembler()

        // Their connection to us.
        var subscriber: CBCentral?

        // The engine-level link.
        var outgoingInvite: Int?
        var hasIncomingInvite = false
        var route: Route?
        var adoptedAt = Date()

        /// True while the engine has, or is setting up, a link over this phone.
        var isInUse: Bool { route != nil || outgoingInvite != nil || hasIncomingInvite }

        init(token: PeerToken) { self.token = token }
    }

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var advertisement: LocalAdvertisement?
    private var beacon = Data()
    private var isRunning = false
    private var reportedProblem: TransportProblem?
    /// Bumped on every stop so that timers from an earlier run do nothing.
    private var generation = 0
    private var serial = 0

    private var remotes: [PeerToken: Remote] = [:]
    private var tokensByPeripheral: [UUID: PeerToken] = [:]
    private var tokensByCentral: [UUID: PeerToken] = [:]
    /// Phones we are connecting to but whose beacon has not been read yet.
    private var connecting: [UUID: CBPeripheral] = [:]
    /// Remembered phones that are out of reach, each with one connect request left
    /// waiting (ours, or iOS's own automatic reconnect). Never more than one per phone.
    private var pending: [UUID: CBPeripheral] = [:]
    /// Which phones are worth waiting for. Survives `stop` (and so a Bluetooth restart),
    /// but not the end of the process; nothing is written to disk.
    private var reconnect = ReconnectPolicy()
    /// The beacon nonce last read from each remembered address. When the same nonce shows
    /// up under a new address (iPhones change their Bluetooth address every few minutes),
    /// the old address will not come back, so its waiting request is withdrawn.
    private var nonceByAddress: [UUID: Data] = [:]
    /// Remembered phones in back-off after quick failures: no new request before this time,
    /// even if a scan sees them.
    private var retryAt: [UUID: Date] = [:]
    private var linkLog = LinkEventLog()
    private var linkEventListeners: [UUID: AsyncStream<LinkEvent>.Continuation] = [:]
    /// Connections handed back by iOS after it relaunched the app; sorted out once
    /// Bluetooth is on (see `readopt`).
    private var restoredPeripherals: [CBPeripheral] = []
    /// Bluetooth addresses not worth connecting to again for a while: a second address
    /// of a phone we already hold, or one that failed. Maps to the time the pause ends.
    private var ignored: [UUID: Date] = [:]

    private var outbox: CBMutableCharacteristic?
    /// The service currently offered; callbacks about earlier ones are ignored.
    private var publishedService: CBMutableService?
    /// Connections closed by `stop`, whose late "disconnected" callbacks must not be
    /// mistaken for a newer connection to the same phone dropping.
    private var cancelled: [UUID: Date] = [:]
    private var subscribers: [UUID: CBCentral] = [:]
    private var inbound: [UUID: BluetoothWire.Reassembler] = [:]
    private var notifyQueue: [(chunk: Data, central: CBCentral)] = []
    /// Bytes in `notifyQueue` per phone, and whether the last chunk sent to it was a
    /// "more follows" one (see `OutgoingBudget`).
    private var notifyBudgets: [UUID: OutgoingBudget] = [:]
    private var notifyMidFrame: [UUID: Bool] = [:]

    public override init() { super.init() }

    // MARK: Transport

    public func start(_ advertisement: LocalAdvertisement) {
        stop()
        self.advertisement = advertisement
        beacon = BluetoothWire.beacon(advertisement)
        isRunning = true
        reportedProblem = nil

        // Creating the managers is what makes iOS ask for Bluetooth access. They are
        // kept for the life of the app so iOS can hand connections back after a relaunch.
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: Self.centralOptions)
        }
        if advertisement.isVisible, peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: Self.peripheralOptions)
        }
        if let central, central.state != .unknown, central.state != .resetting {
            let generation = generation
            // Reported on the next turn of the run loop, like every other radio event.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, let central = self.central else { return }
                self.centralStateChanged(central.state)
            }
        }
        if peripheralManager?.state == .poweredOn { publish() }
        rescanPeriodically()
        sampleSignalPeriodically()
    }

    /// A scan reports each phone once, so it is restarted now and then to pick up phones
    /// whose pause has ended or for which there was no free slot earlier.
    private func rescanPeriodically() {
        after(Self.rescanInterval) { transport in
            transport.scan()
            transport.rescanPeriodically()
        }
    }

    public func stop() {
        isRunning = false
        generation += 1
        cancelled = cancelled.filter { $0.value.timeIntervalSinceNow > -5 }
        if let central, central.state == .poweredOn {
            central.stopScan()
            // Waiting requests are cancelled too; `reconnect` still remembers the phones, so
            // the next `start` (for example once Bluetooth is back on) asks again.
            for peripheral in Array(connecting.values) + Array(pending.values) + remotes.values.compactMap(\.peripheral) {
                peripheral.delegate = nil
                cancelled[peripheral.identifier] = Date()
                central.cancelPeripheralConnection(peripheral)
            }
        }
        if let peripheralManager, peripheralManager.state == .poweredOn {
            peripheralManager.stopAdvertising()
            // Phones connected to us notice the service disappearing and let go.
            peripheralManager.removeAllServices()
        }
        forgetEverything()
        advertisement = nil
    }

    public func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {
        guard let remote = remotes[peer], remote.peripheral != nil, remote.inbox != nil, let advertisement else {
            emitLater(.disconnected(peer))
            return
        }
        closeRoute(of: remote)
        serial += 1
        let serial = serial
        remote.outgoingInvite = serial
        write(BluetoothWire.frame(.invite, BluetoothWire.inviteBody(nonce: advertisement.nonce, context: context)), to: remote)
        after(timeout) { transport in
            guard let remote = transport.remotes[peer], remote.outgoingInvite == serial else { return }
            remote.outgoingInvite = nil
            transport.write(BluetoothWire.frame(.close), to: remote)
            transport.emit(.disconnected(peer))
        }
    }

    public func respondToInvitation(from peer: PeerToken, accept: Bool) {
        guard let remote = remotes[peer], remote.hasIncomingInvite, let subscriber = remote.subscriber else {
            // The invitation was withdrawn or the phone left. Let the engine know its
            // accepted link is not going to happen.
            if accept { emitLater(.disconnected(peer)) }
            return
        }
        remote.hasIncomingInvite = false
        guard accept else {
            notify(BluetoothWire.frame(.decline), to: subscriber)
            return
        }
        // Their invitation wins over anything we had going in the other direction.
        closeRoute(of: remote)
        if remote.outgoingInvite != nil {
            remote.outgoingInvite = nil
            write(BluetoothWire.frame(.close), to: remote)
        }
        remote.route = .asPeripheral
        linkOpened(remote)
        notify(BluetoothWire.frame(.accept), to: subscriber)
        emitLater(.connected(peer))
    }

    public func send(_ data: Data, to peer: PeerToken) throws {
        guard let remote = remotes[peer], let route = remote.route else { throw TransportError.notConnected }
        let frame = BluetoothWire.frame(.data, data)
        let accepted: Bool
        switch route {
        case .asCentral:
            guard remote.peripheral != nil, remote.inbox != nil else { throw TransportError.notConnected }
            accepted = write(frame, to: remote, limited: true)
        case .asPeripheral:
            guard let subscriber = remote.subscriber else { throw TransportError.notConnected }
            accepted = notify(frame, to: subscriber, limited: true)
        }
        guard accepted else {
            shedLoad(remote)
            throw TransportError.notConnected
        }
    }

    /// More than `OutgoingBudget.limit` bytes are waiting for this phone: the engine is
    /// sending far faster than Bluetooth can carry, which honest use never does. Rather
    /// than grow without bound, or drop frames in the middle of a stream, the link is
    /// closed: the frame already on its way is finished, everything after it is dropped,
    /// "close" is sent, and the engine gets `.disconnected` (and re-handshakes later as
    /// after any drop). The Bluetooth connection itself stays.
    private func shedLoad(_ remote: Remote) {
        log("send queue over \(OutgoingBudget.limit) bytes, closing the link to \(remote.token.rawValue)")
        switch remote.route {
        case .asCentral:
            let keep = OutgoingBudget.chunksFinishingCurrentFrame(remote.writeQueue, midFrame: remote.writeMidFrame)
            remote.writeQueue.removeSubrange(keep...)
            remote.queued.reset(to: remote.writeQueue.reduce(0) { $0 + $1.count })
        case .asPeripheral:
            guard let id = remote.subscriber?.identifier else { break }
            let mine = notifyQueue.filter { $0.central.identifier == id }.map(\.chunk)
            let keep = OutgoingBudget.chunksFinishingCurrentFrame(mine, midFrame: notifyMidFrame[id] ?? false)
            var seen = 0
            notifyQueue.removeAll { entry in
                guard entry.central.identifier == id else { return false }
                seen += 1
                return seen > keep
            }
            notifyBudgets[id] = OutgoingBudget()
            notifyBudgets[id]?.reset(to: mine.prefix(keep).reduce(0) { $0 + $1.count })
        case nil:
            break
        }
        closeRoute(of: remote)
        emitLater(.disconnected(remote.token))
    }

    public func disconnect(_ peer: PeerToken) {
        guard let remote = remotes[peer] else { return }
        // Only the engine link ends. The engine also does this after errors (a slow
        // handshake, a protocol slip), so the phone stays remembered: when its Bluetooth
        // connection later drops, a request is left waiting as usual. `forget` is the way
        // to stop that.
        closeRoute(of: remote)
        if remote.outgoingInvite != nil {
            remote.outgoingInvite = nil
            write(BluetoothWire.frame(.close), to: remote)
        }
        // An invitation from them that is still waiting for an answer is left alone.
    }

    /// Stops waiting for this phone: every address it has used is forgotten and any waiting
    /// request withdrawn. A connection that is open stays open, like the one to any other
    /// nearby phone: it shows the phone in "Find nearby", costs no radio time while idle,
    /// and is let go when a slot is needed (`freeSlotIfPossible`). Closing it would only
    /// make the next scan connect again a minute later.
    public func forget(_ peer: PeerToken) {
        guard let remote = remotes[peer] else { return }
        let addresses = LinkTriage.addresses(of: remote.peripheral?.identifier, nonce: remote.nonce,
                                             nonceByAddress: nonceByAddress)
        for id in addresses {
            reconnect.forget(id)
            nonceByAddress[id] = nil
            retryAt[id] = nil
            stopWaiting(for: id)
        }
        log("forgot a phone (\(addresses.count) address(es))")
    }

    /// Forgets every remembered phone and clears the link diagnostics (used when everything
    /// on this phone is erased).
    public func forgetAllPeers() {
        Array(pending.keys).forEach(stopWaiting)
        reconnect.forgetAll()
        nonceByAddress.removeAll()
        retryAt.removeAll()
        linkLog.removeAll()
    }

    // MARK: Shared helpers

    /// The restore identifiers let iOS relaunch Earshot in the background after it
    /// removed the app from memory, when a nearby phone connects.
    private static var centralOptions: [String: Any] {
        #if os(iOS)
        [CBCentralManagerOptionRestoreIdentifierKey: "app.earshot.central"]
        #else
        [:]
        #endif
    }

    private static var peripheralOptions: [String: Any] {
        #if os(iOS)
        [CBPeripheralManagerOptionRestoreIdentifierKey: "app.earshot.peripheral"]
        #else
        [:]
        #endif
    }

    private func emit(_ event: TransportEvent) { eventHandler?(event) }

    private static let logger = Logger(subsystem: "app.earshot", category: "bluetooth")
    private static let echoesLog = ProcessInfo.processInfo.environment["EARSHOT_BT_DEBUG"] != nil

    /// Radio-level diagnostics. Never contains names, keys or message contents.
    private func log(_ message: @autoclosure () -> String) {
        let text = message()
        Self.logger.debug("\(text, privacy: .public)")
        if Self.echoesLog { FileHandle.standardError.write(Data("[bt] \(text)\n".utf8)) }
    }

    private func emitLater(_ event: TransportEvent) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.emit(event)
        }
    }

    private func after(_ delay: TimeInterval, _ action: @escaping @MainActor (BluetoothTransport) -> Void) {
        let generation = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == generation else { return }
            action(self)
        }
    }

    private func forgetEverything() {
        remotes.removeAll()
        tokensByPeripheral.removeAll()
        tokensByCentral.removeAll()
        connecting.removeAll()
        pending.removeAll()
        retryAt.removeAll()
        ignored.removeAll()
        subscribers.removeAll()
        inbound.removeAll()
        notifyQueue.removeAll()
        notifyBudgets.removeAll()
        notifyMidFrame.removeAll()
        outbox = nil
        publishedService = nil
    }

    private func makeRemote(nonce: Data?) -> Remote {
        serial += 1
        let remote = Remote(token: PeerToken(rawValue: "bt#\(serial)"))
        remote.nonce = nonce
        remotes[remote.token] = remote
        return remote
    }

    /// Ends the engine-level link locally and tells the other phone.
    private func closeRoute(of remote: Remote) {
        guard let route = remote.route else { return }
        remote.route = nil
        record(.linkDown, peer: label(of: remote))
        switch route {
        case .asCentral: write(BluetoothWire.frame(.close), to: remote)
        case .asPeripheral:
            if let subscriber = remote.subscriber { notify(BluetoothWire.frame(.close), to: subscriber) }
        }
    }

    private func report(_ problem: TransportProblem) {
        // Every Bluetooth connection is gone at this point.
        forgetEverything()
        guard isRunning, reportedProblem != problem else { return }
        reportedProblem = problem
        emit(.unavailable(problem))
    }

    // MARK: Link diagnostics

    /// The newest link events (at most 500), oldest first. Memory only; see `LinkEvent`.
    public func diagnostics() -> [LinkEvent] { linkLog.events }

    /// Every link event from now on, as it happens. The stream ends when the caller stops
    /// iterating it. It keeps up to 500 events a slow reader has not taken yet.
    public func linkEvents() -> AsyncStream<LinkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self,
                                                            bufferingPolicy: .bufferingNewest(LinkEventLog.defaultCapacity))
        let id = UUID()
        linkEventListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.linkEventListeners[id] = nil }
        }
        return stream
    }

    public func clearDiagnostics() { linkLog.removeAll() }

    private func record(_ kind: LinkEvent.Kind, peer: String, rssi: Int? = nil) {
        let event = LinkEvent(date: Date(), kind: kind, peer: peer, rssi: rssi, appState: appState)
        linkLog.append(event)
        for listener in linkEventListeners.values { listener.yield(event) }
    }

    private var appState: LinkEvent.AppState {
        #if os(iOS)
        UIApplication.shared.applicationState == .background ? .background : .foreground
        #else
        .foreground
        #endif
    }

    private func label(of remote: Remote) -> String {
        if let id = remote.peripheral?.identifier ?? remote.subscriber?.identifier { return LinkEvent.label(for: id) }
        return remote.token.rawValue
    }

    /// Reads the signal strength of every linked phone now and then, only while Earshot
    /// is on screen (it costs a little radio time and is only useful for measuring range).
    private func sampleSignalPeriodically() {
        after(Self.signalInterval) { transport in
            if transport.appState == .foreground {
                for remote in transport.remotes.values where remote.route != nil {
                    remote.peripheral?.readRSSI()
                }
            }
            transport.sampleSignalPeriodically()
        }
    }

    // MARK: Waiting for known phones to come back

    /// Asks iOS to reconnect by itself if the link drops later (iOS 17 / macOS 14, which is
    /// also this package's minimum, so no availability check is needed).
    private static var reconnectOptions: [String: Any] {
        [CBConnectPeripheralOptionEnableAutoReconnect: true]
    }

    /// The engine opened a link over this phone: remember its Bluetooth address.
    private func linkOpened(_ remote: Remote) {
        if let id = remote.peripheral?.identifier {
            if let evicted = reconnect.linkUp(id) { stopWaiting(for: evicted) }
            if let nonce = remote.nonce { nonceByAddress[id] = nonce }
        }
        record(.linkUp, peer: label(of: remote))
    }

    /// Leaves one connect request open for a remembered phone, with no time limit.
    /// `requestConnect` is false when iOS already has one open: its automatic reconnect,
    /// or a request carried over a relaunch.
    private func waitForReturn(of peripheral: CBPeripheral, requestConnect: Bool) {
        let id = peripheral.identifier
        guard isRunning, let central, central.state == .poweredOn, reconnect.isRemembered(id),
              pending[id] == nil, connecting[id] == nil, tokensByPeripheral[id] == nil else { return }
        if let nonce = nonceByAddress[id],
           tokensByPeripheral.keys.contains(where: { $0 != id && nonceByAddress[$0] == nonce }) {
            // The same phone is already connected under a newer address; this one is stale.
            reconnect.forget(id)
            nonceByAddress[id] = nil
            return
        }
        pending[id] = peripheral
        // From here a late "disconnected" from an earlier cancel is recognised by `pending`.
        cancelled[id] = nil
        ignored[id] = nil
        peripheral.delegate = self
        if requestConnect {
            central.connect(peripheral, options: Self.reconnectOptions)
            record(.connectRequested, peer: LinkEvent.label(for: id))
        } else {
            record(.reconnecting, peer: LinkEvent.label(for: id))
        }
        log("waiting for a known phone to come back")
    }

    private func stopWaiting(for id: UUID) {
        guard let peripheral = pending.removeValue(forKey: id) else { return }
        peripheral.delegate = nil
        guard let central, central.state == .poweredOn else { return }
        cancelled[id] = Date()
        central.cancelPeripheralConnection(peripheral)
    }

    private func apply(_ decision: ReconnectPolicy.Decision, to peripheral: CBPeripheral, afterCancel: Bool) {
        switch decision {
        case .giveUp:
            break
        case .waitForSystem:
            waitForReturn(of: peripheral, requestConnect: false)
        case .connect(let delay):
            // Right after a cancel, give iOS a moment to finish it before asking again.
            let delay = afterCancel ? max(delay, 1) : delay
            let id = peripheral.identifier
            if delay <= 0 {
                waitForReturn(of: peripheral, requestConnect: true)
            } else {
                retryAt[id] = Date().addingTimeInterval(delay)
                after(delay) { transport in
                    transport.retryAt[id] = nil
                    transport.waitForReturn(of: peripheral, requestConnect: true)
                }
            }
        }
    }

    /// The phone that uses `nonce` is now connected at `id`. Any other remembered address
    /// with the same nonce belongs to the same phone and is stale.
    private func retireOldAddresses(of nonce: Data, now id: UUID) {
        nonceByAddress = nonceByAddress.filter { reconnect.isRemembered($0.key) }
        for (other, otherNonce) in nonceByAddress where other != id && otherNonce == nonce
            && connecting[other] == nil && tokensByPeripheral[other] == nil {
            stopWaiting(for: other)
            reconnect.forget(other)
            nonceByAddress[other] = nil
            log("a known phone came back under a new address")
        }
        nonceByAddress[id] = nonce
    }

    /// Bluetooth is (back) on: a waiting request for every remembered phone that has none.
    private func resumeRemembered() {
        guard isRunning, let central, central.state == .poweredOn else { return }
        let missing = reconnect.remembered.filter {
            pending[$0] == nil && connecting[$0] == nil && tokensByPeripheral[$0] == nil
        }
        guard !missing.isEmpty else { return }
        for peripheral in central.retrievePeripherals(withIdentifiers: missing) {
            waitForReturn(of: peripheral, requestConnect: true)
        }
    }

    /// iOS relaunched the app and handed back the Bluetooth connections it held for us.
    /// - A request still waiting was left for a phone we had linked with, so it is taken
    ///   over as it is, not asked for a second time.
    /// - An open connection is closed: the session keys that went with it died with the
    ///   old process. It is replaced by a waiting request, so the two phones link up again
    ///   from scratch as soon as iOS reconnects (normally within a second or two).
    ///
    /// Nothing proves that a link ever ran over these (the old process also connected to
    /// strangers to read their beacons), so they are remembered only provisionally: see
    /// `ReconnectPolicy`.
    private func readopt(_ peripheral: CBPeripheral) {
        guard let central else { return }
        let id = peripheral.identifier
        let action = LinkTriage.onRestore(peripheral.state, isRunning: isRunning)
        guard action != .cancel, reconnect.rememberProvisionally(id) != id else {
            return central.cancelPeripheralConnection(peripheral)
        }
        switch action {
        case .takeOver:
            waitForReturn(of: peripheral, requestConnect: false)
        case .reopen:
            cancelled[id] = Date()
            central.cancelPeripheralConnection(peripheral)
            apply(.connect(after: 0), to: peripheral, afterCancel: true)
        case .cancel:
            break
        }
    }

    // MARK: Central role (we connect to them)

    private func centralStateChanged(_ state: CBManagerState) {
        log("central state \(state.rawValue)")
        switch state {
        case .poweredOn:
            let restored = restoredPeripherals
            restoredPeripherals.removeAll()
            restored.forEach(readopt)
            guard isRunning else { return }
            if reportedProblem != nil {
                reportedProblem = nil
                // The engine restarts the transport in response, which begins scanning.
                emit(.ready)
            }
            scan()
            resumeRemembered()
        case .poweredOff: report(.bluetoothOff)
        case .unauthorized: report(.bluetoothDenied)
        case .unsupported: report(.bluetoothUnsupported)
        case .resetting: loseEverything()
        case .unknown: break
        @unknown default: break
        }
    }

    /// Bluetooth restarted underneath us: every connection object is void. The engine is
    /// told about each link and phone, and discovery starts over once Bluetooth is back.
    private func loseEverything() {
        let linked = remotes.values.filter { $0.route != nil || $0.outgoingInvite != nil }.map(\.token)
        let found = remotes.values.filter { $0.peripheral != nil }.map(\.token)
        forgetEverything()
        guard isRunning else { return }
        linked.forEach { emit(.disconnected($0)) }
        found.forEach { emit(.lost($0)) }
    }

    private func scan() {
        guard isRunning, let central, central.state == .poweredOn else { return }
        // A phone is reported once per scan, so the scan is restarted whenever a phone
        // has to be found again.
        central.stopScan()
        central.scanForPeripherals(withServices: [Self.serviceID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Queues a frame for a phone we connected to. With `limited`, refuses it (returns
    /// false) when the queue would go over `OutgoingBudget.limit`; control frames always go.
    @discardableResult
    private func write(_ frame: Data, to remote: Remote, limited: Bool = false) -> Bool {
        guard let peripheral = remote.peripheral else { return false }
        let length = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        let chunks = BluetoothWire.chunks(of: frame, maxChunkLength: length)
        let size = chunks.reduce(0) { $0 + $1.count }
        if limited {
            guard remote.queued.admit(size) else { return false }
        } else {
            remote.queued.force(size)
        }
        remote.writeQueue.append(contentsOf: chunks)
        pumpWrites(remote)
        return true
    }

    /// One chunk at a time, each confirmed by the other phone before the next goes out.
    private func pumpWrites(_ remote: Remote) {
        guard !remote.isWriting, !remote.writeQueue.isEmpty,
              let peripheral = remote.peripheral, let inbox = remote.inbox else { return }
        remote.isWriting = true
        let chunk = remote.writeQueue.removeFirst()
        remote.queued.sent(chunk.count)
        remote.writeMidFrame = chunk.first == 0
        peripheral.writeValue(chunk, for: inbox, type: .withResponse)
    }

    /// Our connection to a phone is gone (or unusable). `ending` says why, which decides
    /// whether a connect request is left waiting for it (see `ReconnectPolicy`).
    private func dropPeripheral(_ peripheral: CBPeripheral, cancel: Bool, pause: TimeInterval? = nil,
                                ending: ReconnectPolicy.Ending) {
        let id = peripheral.identifier
        peripheral.delegate = nil
        if let pause { ignored[id] = Date().addingTimeInterval(pause) }
        if cancel, let central, central.state == .poweredOn {
            // Its "disconnected" callback is expected and must not count as a second drop.
            cancelled[id] = Date()
            central.cancelPeripheralConnection(peripheral)
        }
        let wasPending = pending.removeValue(forKey: id) != nil
        let wasKnown = connecting.removeValue(forKey: id) != nil || tokensByPeripheral[id] != nil
        if let token = tokensByPeripheral.removeValue(forKey: id), let remote = remotes[token] {
            let hadLink = remote.route == .asCentral || remote.outgoingInvite != nil
            if remote.route == .asCentral {
                remote.route = nil
                record(.linkDown, peer: LinkEvent.label(for: id))
            }
            remote.outgoingInvite = nil
            remote.peripheral = nil
            remote.inbox = nil
            remote.writeQueue.removeAll()
            remote.queued.reset()
            remote.writeMidFrame = false
            remote.isWriting = false
            remote.fromPeripheral.reset()
            if remote.subscriber == nil { remotes[token] = nil }
            // Its other Bluetooth addresses were being skipped; one of them is now the way back.
            ignored = ignored.filter { $0.key == id }
            log("lost \(token.rawValue)")
            if hadLink { emit(.disconnected(token)) }
            emit(.lost(token))
        }
        // A paused address is not looked for again right away; the periodic rescan does that.
        if wasKnown, pause == nil { scan() }
        guard wasKnown || wasPending else { return }
        let decision = reconnect.decide(id, ending)
        var afterCancel = cancel
        if ending == .systemReconnecting, case .connect = decision, let central, central.state == .poweredOn {
            // Too many quick drops in a row: stop iOS's immediate reconnect and wait out the back-off.
            cancelled[id] = Date()
            central.cancelPeripheralConnection(peripheral)
            afterCancel = true
        }
        apply(decision, to: peripheral, afterCancel: afterCancel)
    }

    /// Makes room when every slot is taken, by letting go of the phone that has been
    /// held longest without anyone connecting to it.
    private func freeSlotIfPossible() -> Bool {
        let idle = remotes.values.filter {
            $0.peripheral != nil && !$0.isInUse && $0.adoptedAt.timeIntervalSinceNow < -15
        }
        guard let oldest = idle.min(by: { $0.adoptedAt < $1.adoptedAt }), let peripheral = oldest.peripheral else {
            return false
        }
        dropPeripheral(peripheral, cancel: true, pause: Self.failurePause, ending: .dropped)
        return true
    }

    /// The beacon of a freshly connected phone has been read.
    private func adopt(_ peripheral: CBPeripheral, inbox: CBCharacteristic, _ found: LocalAdvertisement) {
        let id = peripheral.identifier
        guard connecting.removeValue(forKey: id) != nil else { return }
        let sameNonce = remotes.values.first { $0.nonce == found.nonce }
        if let sameNonce, sameNonce.peripheral != nil {
            // The same phone seen under a new Bluetooth address while the old connection
            // still works. Keep the old one.
            connecting[id] = peripheral
            dropPeripheral(peripheral, cancel: true, pause: Self.duplicatePause, ending: .dropped)
            return
        }
        // If this phone already connected to us and named this nonce, it is one and the same.
        let remote = sameNonce ?? makeRemote(nonce: found.nonce)
        remote.peripheral = peripheral
        remote.inbox = inbox
        remote.adoptedAt = Date()
        tokensByPeripheral[id] = remote.token
        retireOldAddresses(of: found.nonce, now: id)
        if reconnect.isRemembered(id) {
            reconnect.cameBack(id)
            // If the engine does not open a link over it soon (the contact was removed, or
            // blocked, while away), stop waiting for this phone the next time it leaves.
            after(ReconnectPolicy.unusedGrace + 1) { transport in
                if transport.reconnect.isUnused(id) { transport.reconnect.forget(id) }
            }
        }
        // Joined to a link that already runs the other way round.
        if remote.route != nil { linkOpened(remote) }
        log("beacon read, found \(remote.token.rawValue)")
        emit(.found(remote.token, found))
    }

    private func frameReceived(_ frame: Data, fromPeripheralOf remote: Remote) {
        guard let (kind, body) = BluetoothWire.parseFrame(frame) else { return }
        let token = remote.token
        switch kind {
        case .accept:
            guard remote.outgoingInvite != nil else { return }
            remote.outgoingInvite = nil
            remote.route = .asCentral
            linkOpened(remote)
            log("invitation accepted by \(token.rawValue)")
            emit(.connected(token))
        case .decline:
            guard remote.outgoingInvite != nil else { return }
            remote.outgoingInvite = nil
            emit(.disconnected(token))
        case .data:
            guard remote.route == .asCentral else { return }
            emit(.received(body, from: token))
        case .close:
            guard remote.route == .asCentral else { return }
            remote.route = nil
            record(.linkDown, peer: label(of: remote))
            emit(.disconnected(token))
        case .invite:
            break
        }
    }

    // MARK: Peripheral role (they connect to us)

    private func publish() {
        guard isRunning, advertisement?.isVisible == true,
              let peripheralManager, peripheralManager.state == .poweredOn else { return }
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        subscribers.removeAll()
        let beacon = CBMutableCharacteristic(type: Self.beaconID, properties: .read, value: nil, permissions: .readable)
        let inbox = CBMutableCharacteristic(type: Self.inboxID, properties: .write, value: nil, permissions: .writeable)
        let outbox = CBMutableCharacteristic(type: Self.outboxID, properties: .notify, value: nil, permissions: .readable)
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [beacon, inbox, outbox]
        self.outbox = outbox
        publishedService = service
        peripheralManager.add(service)
    }

    /// Queues a frame for a phone connected to us. `limited` works as in `write`.
    @discardableResult
    private func notify(_ frame: Data, to central: CBCentral, limited: Bool = false) -> Bool {
        let length = max(central.maximumUpdateValueLength, 20)
        let chunks = BluetoothWire.chunks(of: frame, maxChunkLength: length)
        let size = chunks.reduce(0) { $0 + $1.count }
        let id = central.identifier
        if limited {
            guard notifyBudgets[id, default: OutgoingBudget()].admit(size) else { return false }
        } else {
            notifyBudgets[id, default: OutgoingBudget()].force(size)
        }
        for chunk in chunks { notifyQueue.append((chunk, central)) }
        flushNotifications()
        return true
    }

    private func flushNotifications() {
        guard let peripheralManager, let outbox else { return }
        while let next = notifyQueue.first {
            guard subscribers[next.central.identifier] != nil else {
                notifyQueue.removeFirst()
                notifyBudgets[next.central.identifier]?.sent(next.chunk.count)
                continue
            }
            // `false` means the system's queue is full; it calls back when there is room.
            guard peripheralManager.updateValue(next.chunk, for: outbox, onSubscribedCentrals: [next.central]) else { return }
            notifyQueue.removeFirst()
            notifyBudgets[next.central.identifier]?.sent(next.chunk.count)
            notifyMidFrame[next.central.identifier] = next.chunk.first == 0
        }
    }

    /// A phone that had connected to us is gone.
    private func dropCentral(_ id: UUID) {
        subscribers[id] = nil
        inbound[id] = nil
        notifyQueue.removeAll { $0.central.identifier == id }
        notifyBudgets[id] = nil
        notifyMidFrame[id] = nil
        guard let token = tokensByCentral.removeValue(forKey: id), let remote = remotes[token] else { return }
        let hadLink = remote.route == .asPeripheral
        if hadLink {
            remote.route = nil
            record(.linkDown, peer: LinkEvent.label(for: id))
        }
        remote.hasIncomingInvite = false
        remote.subscriber = nil
        if remote.peripheral == nil { remotes[token] = nil }
        if hadLink { emit(.disconnected(token)) }
    }

    private func frameReceived(_ frame: Data, fromCentral id: UUID) {
        guard let (kind, body) = BluetoothWire.parseFrame(frame) else { return }
        let known = tokensByCentral[id].flatMap { remotes[$0] }
        switch kind {
        case .invite:
            guard let central = subscribers[id], let (nonce, context) = BluetoothWire.parseInviteBody(body) else { return }
            let remote: Remote
            if let known {
                remote = known
            } else if let seen = remotes.values.first(where: { $0.nonce == nonce }) {
                // Already seen nearby under this nonce. Only join the two when nobody else
                // holds that place; the engine verifies who it really is either way.
                remote = seen.subscriber == nil ? seen : makeRemote(nonce: nil)
            } else {
                remote = makeRemote(nonce: nonce)
            }
            remote.subscriber = central
            tokensByCentral[id] = remote.token
            remote.hasIncomingInvite = true
            log("invitation from \(remote.token.rawValue)")
            emit(.invited(by: remote.token, context: context))
        case .data:
            guard let known, known.route == .asPeripheral else { return }
            emit(.received(body, from: known.token))
        case .close:
            guard let known else { return }
            if known.route == .asPeripheral {
                known.route = nil
                record(.linkDown, peer: label(of: known))
                emit(.disconnected(known.token))
            } else {
                // They withdrew an invitation that was still waiting for an answer.
                known.hasIncomingInvite = false
            }
        case .accept, .decline:
            break
        }
    }
}

// MARK: - Core Bluetooth callbacks (all delivered on the main queue)

extension BluetoothTransport: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralStateChanged(central.state)
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // The app was relaunched by iOS. Session keys lived in memory and are gone; what
        // happens to each connection is decided once Bluetooth is on (see `readopt`).
        restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    }
    #endif

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        guard isRunning, connecting[id] == nil, tokensByPeripheral[id] == nil, pending[id] == nil else { return }
        // 127 means "not available" in Core Bluetooth.
        record(.discovered, peer: LinkEvent.label(for: id), rssi: RSSI.intValue == 127 ? nil : RSSI.intValue)
        if reconnect.isRemembered(id) {
            // A phone we linked with before: no pause, no slot limit, no time limit,
            // but a back-off after quick failures is respected.
            if let until = retryAt[id], until > Date() { return }
            return waitForReturn(of: peripheral, requestConnect: true)
        }
        if let until = ignored[id] {
            guard until < Date() else { return }
            ignored[id] = nil
        }
        guard connecting.count + tokensByPeripheral.count < Self.maxPeripherals || freeSlotIfPossible() else { return }
        connecting[id] = peripheral
        log("discovered a phone, connecting (signal \(RSSI))")
        peripheral.delegate = self
        // A first connection to a phone we never linked with gets no automatic reconnect
        // and a time limit: strangers are not chased.
        central.connect(peripheral)
        record(.connectRequested, peer: LinkEvent.label(for: id))
        watchSetup(of: peripheral)
    }

    /// Gives up on a connection that is not ready (beacon read) within `connectTimeout`.
    private func watchSetup(of peripheral: CBPeripheral) {
        let id = peripheral.identifier
        after(Self.connectTimeout) { transport in
            guard let current = transport.connecting[id], current === peripheral else { return }
            transport.record(.connectFailed, peer: LinkEvent.label(for: id))
            transport.dropPeripheral(peripheral, cancel: true, pause: Self.failurePause, ending: .setupFailed)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        if pending.removeValue(forKey: id) != nil {
            // A phone we were waiting for is back. Reading its beacon gets the usual time limit.
            connecting[id] = peripheral
            peripheral.delegate = self
            watchSetup(of: peripheral)
        }
        guard connecting[id] === peripheral else { return }
        log("connected, reading beacon")
        record(.connected, peer: LinkEvent.label(for: id))
        peripheral.readRSSI()
        peripheral.discoverServices([Self.serviceID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("failed to connect: \(error?.localizedDescription ?? "-")")
        record(.connectFailed, peer: LinkEvent.label(for: peripheral.identifier))
        dropPeripheral(peripheral, cancel: false, pause: Self.failurePause, ending: .connectFailed)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionEnded(peripheral, isReconnecting: false, error: error)
    }

    /// iOS 17 / macOS 14 variant. With `CBConnectPeripheralOptionEnableAutoReconnect`,
    /// `isReconnecting` is true when iOS has already started connecting again by itself.
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        connectionEnded(peripheral, isReconnecting: isReconnecting, error: error)
    }

    /// Handles both "disconnected" callbacks. Apple does not document whether one or both
    /// are called when both are implemented, so a second report of the same drop is ignored.
    private func connectionEnded(_ peripheral: CBPeripheral, isReconnecting: Bool, error: Error?) {
        let id = peripheral.identifier
        log("disconnected\(isReconnecting ? " (iOS reconnecting)" : ""): \(error?.localizedDescription ?? "-")")
        let cancelledRecently = cancelled.removeValue(forKey: id).map { $0.timeIntervalSinceNow > -5 } ?? false
        // `alreadyWaiting`: the same drop reported twice, or the late callback of a cancel.
        let action = LinkTriage.onDisconnect(cancelledRecently: cancelledRecently, alreadyWaiting: pending[id] != nil,
                                             remembered: reconnect.isRemembered(id), isReconnecting: isReconnecting)
        switch action {
        case .ignore:
            return
        case .cancelSystemReconnectAndDrop:
            if let central, central.state == .poweredOn {
                cancelled[id] = Date()
                central.cancelPeripheralConnection(peripheral)
            }
            record(.disconnected, peer: LinkEvent.label(for: id))
            dropPeripheral(peripheral, cancel: false, ending: .linkLost)
        case .drop(let ending):
            record(.disconnected, peer: LinkEvent.label(for: id))
            // The engine sees the link drop either way, and re-handshakes once it is back.
            dropPeripheral(peripheral, cancel: false, ending: ending)
        }
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralDelegate {
    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        connecting[peripheral.identifier] === peripheral
            || tokensByPeripheral[peripheral.identifier].flatMap { remotes[$0]?.peripheral } === peripheral
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause, ending: .setupFailed)
        }
        peripheral.discoverCharacteristics([Self.beaconID, Self.inboxID, Self.outboxID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral) else { return }
        let found = service.characteristics ?? []
        guard error == nil, found.contains(where: { $0.uuid == Self.beaconID }),
              found.contains(where: { $0.uuid == Self.inboxID }),
              let outbox = found.first(where: { $0.uuid == Self.outboxID }) else {
            return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause, ending: .setupFailed)
        }
        // Listen first, then read who they are.
        peripheral.setNotifyValue(true, for: outbox)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == Self.outboxID else { return }
        guard error == nil, characteristic.isNotifying,
              let beacon = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.beaconID }) else {
            return dropPeripheral(peripheral, cancel: true, ending: .setupFailed)
        }
        peripheral.readValue(for: beacon)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral) else { return }
        switch characteristic.uuid {
        case Self.beaconID:
            guard error == nil, let value = characteristic.value, let found = BluetoothWire.parseBeacon(value),
                  let inbox = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.inboxID }) else {
                return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause, ending: .setupFailed)
            }
            adopt(peripheral, inbox: inbox, found)
        case Self.outboxID:
            guard error == nil, let chunk = characteristic.value,
                  let remote = tokensByPeripheral[peripheral.identifier].flatMap({ remotes[$0] }) else { return }
            do {
                if let frame = try remote.fromPeripheral.append(chunk) { frameReceived(frame, fromPeripheralOf: remote) }
            } catch {
                dropPeripheral(peripheral, cancel: true, ending: .setupFailed)
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral),
              let remote = tokensByPeripheral[peripheral.identifier].flatMap({ remotes[$0] }) else { return }
        guard error == nil else { return dropPeripheral(peripheral, cancel: true, ending: .setupFailed) }
        remote.isWriting = false
        pumpWrites(remote)
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The other phone restarted Earshot: its old beacon and link are void.
        guard isCurrent(peripheral), invalidatedServices.contains(where: { $0.uuid == Self.serviceID }) else { return }
        // Reconnecting (if remembered) reads its new beacon.
        dropPeripheral(peripheral, cancel: true, ending: .linkLost)
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, isCurrent(peripheral), RSSI.intValue != 127 else { return }
        record(.signal, peer: LinkEvent.label(for: peripheral.identifier), rssi: RSSI.intValue)
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        // Problems are reported once, by the central manager.
        log("peripheral state \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn: publish()
        case .resetting: loseEverything()
        default: break
        }
    }

    #if os(iOS)
    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Nothing to carry over: `publish` replaces the service with a fresh one.
    }
    #endif

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard isRunning, service === publishedService else { return }
        if let error {
            emit(.unavailable(.failedToStart(error.localizedDescription)))
            return
        }
        // Only the service is announced. The name is not part of the broadcast; it is
        // read over a connection, and only when this phone is set to be visible.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        // Not fatal: this phone can still find others and be reached over links it opens.
        log("advertising: \(error?.localizedDescription ?? "started")")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard isRunning, request.characteristic.uuid == Self.beaconID else {
            return peripheral.respond(to: request, withResult: .readNotPermitted)
        }
        guard request.offset <= beacon.count else {
            return peripheral.respond(to: request, withResult: .invalidOffset)
        }
        request.value = Data(beacon.dropFirst(request.offset))
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard isRunning else { return peripheral.respond(to: first, withResult: .writeNotPermitted) }
        // All or nothing: check every request before applying any of them.
        for request in requests {
            guard request.characteristic.uuid == Self.inboxID, request.value != nil else {
                return peripheral.respond(to: first, withResult: .requestNotSupported)
            }
            // Only phones that are listening for our answers may write.
            guard subscribers[request.central.identifier] != nil else {
                return peripheral.respond(to: first, withResult: .insufficientAuthorization)
            }
        }
        // A chunk too big for one Bluetooth packet arrives as a "long write": several requests
        // with growing offsets. Join them back into one chunk first (see `mergeWrites`).
        // Requests with an offset that do not continue the previous one are refused.
        let pieces = requests.map {
            BluetoothWire.WritePiece(writer: $0.central.identifier, offset: $0.offset, value: $0.value ?? Data())
        }
        guard let writes = BluetoothWire.mergeWrites(pieces) else {
            return peripheral.respond(to: first, withResult: .invalidOffset)
        }
        for (id, value) in writes {
            let linked = tokensByCentral[id].flatMap { remotes[$0] }?.route == .asPeripheral
            let limit = linked ? BluetoothWire.maxFrameLength : BluetoothWire.maxUnlinkedFrameLength
            do {
                if let frame = try inbound[id, default: BluetoothWire.Reassembler()].append(value, limit: limit) {
                    frameReceived(frame, fromCentral: id)
                }
            } catch {
                inbound[id] = nil
                return peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            }
        }
        peripheral.respond(to: first, withResult: .success)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard isRunning, characteristic.uuid == Self.outboxID else { return }
        subscribers[central.identifier] = central
        log("a phone connected to us")
        if let token = tokensByCentral[central.identifier] { remotes[token]?.subscriber = central }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.outboxID else { return }
        log("a phone that was connected to us left")
        dropCentral(central.identifier)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushNotifications()
    }
}
