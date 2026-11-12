@preconcurrency import CoreBluetooth
import Foundation
import os

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
    /// Connections handed back by iOS after it relaunched the app; closed on start.
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
            for peripheral in Array(connecting.values) + remotes.values.compactMap(\.peripheral) {
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
        notify(BluetoothWire.frame(.accept), to: subscriber)
        emitLater(.connected(peer))
    }

    public func send(_ data: Data, to peer: PeerToken) throws {
        guard let remote = remotes[peer], let route = remote.route else { throw TransportError.notConnected }
        let frame = BluetoothWire.frame(.data, data)
        switch route {
        case .asCentral:
            guard remote.peripheral != nil, remote.inbox != nil else { throw TransportError.notConnected }
            write(frame, to: remote)
        case .asPeripheral:
            guard let subscriber = remote.subscriber else { throw TransportError.notConnected }
            notify(frame, to: subscriber)
        }
    }

    public func disconnect(_ peer: PeerToken) {
        guard let remote = remotes[peer] else { return }
        closeRoute(of: remote)
        if remote.outgoingInvite != nil {
            remote.outgoingInvite = nil
            write(BluetoothWire.frame(.close), to: remote)
        }
        // An invitation from them that is still waiting for an answer is left alone.
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
        ignored.removeAll()
        subscribers.removeAll()
        inbound.removeAll()
        notifyQueue.removeAll()
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

    // MARK: Central role (we connect to them)

    private func centralStateChanged(_ state: CBManagerState) {
        log("central state \(state.rawValue)")
        switch state {
        case .poweredOn:
            guard let central else { return }
            restoredPeripherals.forEach(central.cancelPeripheralConnection)
            restoredPeripherals.removeAll()
            guard isRunning else { return }
            if reportedProblem != nil {
                reportedProblem = nil
                // The engine restarts the transport in response, which begins scanning.
                emit(.ready)
            }
            if isRunning { scan() }
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

    private func write(_ frame: Data, to remote: Remote) {
        guard let peripheral = remote.peripheral else { return }
        let length = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)
        remote.writeQueue.append(contentsOf: BluetoothWire.chunks(of: frame, maxChunkLength: length))
        pumpWrites(remote)
    }

    /// One chunk at a time, each confirmed by the other phone before the next goes out.
    private func pumpWrites(_ remote: Remote) {
        guard !remote.isWriting, !remote.writeQueue.isEmpty,
              let peripheral = remote.peripheral, let inbox = remote.inbox else { return }
        remote.isWriting = true
        peripheral.writeValue(remote.writeQueue.removeFirst(), for: inbox, type: .withResponse)
    }

    /// Our connection to a phone is gone (or unusable).
    private func dropPeripheral(_ peripheral: CBPeripheral, cancel: Bool, pause: TimeInterval? = nil) {
        let id = peripheral.identifier
        peripheral.delegate = nil
        if let pause { ignored[id] = Date().addingTimeInterval(pause) }
        if cancel, let central, central.state == .poweredOn { central.cancelPeripheralConnection(peripheral) }
        let wasKnown = connecting.removeValue(forKey: id) != nil || tokensByPeripheral[id] != nil
        if let token = tokensByPeripheral.removeValue(forKey: id), let remote = remotes[token] {
            let hadLink = remote.route == .asCentral || remote.outgoingInvite != nil
            if remote.route == .asCentral { remote.route = nil }
            remote.outgoingInvite = nil
            remote.peripheral = nil
            remote.inbox = nil
            remote.writeQueue.removeAll()
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
        dropPeripheral(peripheral, cancel: true, pause: Self.failurePause)
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
            dropPeripheral(peripheral, cancel: true, pause: Self.duplicatePause)
            return
        }
        // If this phone already connected to us and named this nonce, it is one and the same.
        let remote = sameNonce ?? makeRemote(nonce: found.nonce)
        remote.peripheral = peripheral
        remote.inbox = inbox
        remote.adoptedAt = Date()
        tokensByPeripheral[id] = remote.token
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

    private func notify(_ frame: Data, to central: CBCentral) {
        let length = max(central.maximumUpdateValueLength, 20)
        for chunk in BluetoothWire.chunks(of: frame, maxChunkLength: length) {
            notifyQueue.append((chunk, central))
        }
        flushNotifications()
    }

    private func flushNotifications() {
        guard let peripheralManager, let outbox else { return }
        while let next = notifyQueue.first {
            guard subscribers[next.central.identifier] != nil else {
                notifyQueue.removeFirst()
                continue
            }
            // `false` means the system's queue is full; it calls back when there is room.
            guard peripheralManager.updateValue(next.chunk, for: outbox, onSubscribedCentrals: [next.central]) else { return }
            notifyQueue.removeFirst()
        }
    }

    /// A phone that had connected to us is gone.
    private func dropCentral(_ id: UUID) {
        subscribers[id] = nil
        inbound[id] = nil
        notifyQueue.removeAll { $0.central.identifier == id }
        guard let token = tokensByCentral.removeValue(forKey: id), let remote = remotes[token] else { return }
        let hadLink = remote.route == .asPeripheral
        if hadLink { remote.route = nil }
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
        // The app was relaunched by iOS. Session keys lived in memory and are gone, so
        // old connections are closed and both phones link up again from scratch.
        restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    }
    #endif

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        guard isRunning, connecting[id] == nil, tokensByPeripheral[id] == nil else { return }
        if let until = ignored[id] {
            guard until < Date() else { return }
            ignored[id] = nil
        }
        guard connecting.count + tokensByPeripheral.count < Self.maxPeripherals || freeSlotIfPossible() else { return }
        connecting[id] = peripheral
        log("discovered a phone, connecting (signal \(RSSI))")
        peripheral.delegate = self
        central.connect(peripheral)
        after(Self.connectTimeout) { transport in
            guard let pending = transport.connecting[id], pending === peripheral else { return }
            transport.dropPeripheral(peripheral, cancel: true, pause: Self.failurePause)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connecting[peripheral.identifier] === peripheral else { return }
        log("connected, reading beacon")
        peripheral.discoverServices([Self.serviceID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("failed to connect: \(error?.localizedDescription ?? "-")")
        dropPeripheral(peripheral, cancel: false, pause: Self.failurePause)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "-")")
        if let at = cancelled.removeValue(forKey: peripheral.identifier), at.timeIntervalSinceNow > -5 { return }
        dropPeripheral(peripheral, cancel: false)
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
            return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause)
        }
        peripheral.discoverCharacteristics([Self.beaconID, Self.inboxID, Self.outboxID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral) else { return }
        let found = service.characteristics ?? []
        guard error == nil, found.contains(where: { $0.uuid == Self.beaconID }),
              found.contains(where: { $0.uuid == Self.inboxID }),
              let outbox = found.first(where: { $0.uuid == Self.outboxID }) else {
            return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause)
        }
        // Listen first, then read who they are.
        peripheral.setNotifyValue(true, for: outbox)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == Self.outboxID else { return }
        guard error == nil, characteristic.isNotifying,
              let beacon = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.beaconID }) else {
            return dropPeripheral(peripheral, cancel: true)
        }
        peripheral.readValue(for: beacon)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral) else { return }
        switch characteristic.uuid {
        case Self.beaconID:
            guard error == nil, let value = characteristic.value, let found = BluetoothWire.parseBeacon(value),
                  let inbox = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.inboxID }) else {
                return dropPeripheral(peripheral, cancel: true, pause: Self.failurePause)
            }
            adopt(peripheral, inbox: inbox, found)
        case Self.outboxID:
            guard error == nil, let chunk = characteristic.value,
                  let remote = tokensByPeripheral[peripheral.identifier].flatMap({ remotes[$0] }) else { return }
            do {
                if let frame = try remote.fromPeripheral.append(chunk) { frameReceived(frame, fromPeripheralOf: remote) }
            } catch {
                dropPeripheral(peripheral, cancel: true)
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral),
              let remote = tokensByPeripheral[peripheral.identifier].flatMap({ remotes[$0] }) else { return }
        guard error == nil else { return dropPeripheral(peripheral, cancel: true) }
        remote.isWriting = false
        pumpWrites(remote)
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The other phone restarted Earshot: its old beacon and link are void.
        guard isCurrent(peripheral), invalidatedServices.contains(where: { $0.uuid == Self.serviceID }) else { return }
        dropPeripheral(peripheral, cancel: true)
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
            guard request.characteristic.uuid == Self.inboxID, request.offset == 0, request.value != nil else {
                return peripheral.respond(to: first, withResult: .requestNotSupported)
            }
            // Only phones that are listening for our answers may write.
            guard subscribers[request.central.identifier] != nil else {
                return peripheral.respond(to: first, withResult: .insufficientAuthorization)
            }
        }
        for request in requests {
            let id = request.central.identifier
            let linked = tokensByCentral[id].flatMap { remotes[$0] }?.route == .asPeripheral
            let limit = linked ? BluetoothWire.maxFrameLength : BluetoothWire.maxUnlinkedFrameLength
            do {
                if let frame = try inbound[id, default: BluetoothWire.Reassembler()].append(request.value ?? Data(), limit: limit) {
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
