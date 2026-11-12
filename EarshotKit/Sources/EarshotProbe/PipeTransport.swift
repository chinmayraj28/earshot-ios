// A pretend Bluetooth radio that talks over this process's stdin and stdout, so the web
// client's tests can run the real Swift `Messenger` as "the phone" without any radio.
//
// Debug builds only (it needs `@testable import` to reuse the real `BluetoothWire` code).
//
// It plays the phone's PERIPHERAL role exactly like `BluetoothTransport` does when a browser
// connects to it: the browser is the central, it must subscribe to the outbox before it may
// write, it reads the beacon, and it writes chunked frames into the inbox. The phone answers
// with chunked notifications. Each line is one Bluetooth operation; bytes are base64.
//
//   browser -> probe (stdin)              probe -> browser (stdout)
//   GATT connect                          (nothing)
//   GATT subscribe                        GATT subscribed
//   GATT read                             GATT beacon <base64>
//   GATT write <base64 chunk>             GATT write-ok   or   GATT write-error <reason>
//   GATT disconnect                       (nothing; the phone forgets the browser)
//                                         GATT notify <base64 chunk>
//
// Example: a 300-byte frame sent by the phone with `--pipe-chunk 20` arrives as 16
// `GATT notify` lines, each starting with the chunk marker byte (0 = more, 1 = last).
// Lines that do not start with "GATT " are ordinary probe output (CONNECTED, RECEIVED ...).

#if DEBUG
@testable import EarshotKit
import Foundation

@MainActor
final class PipeTransport: Transport {
    var eventHandler: ((TransportEvent) -> Void)?

    /// Largest notification chunk, marker byte included. Like `central.maximumUpdateValueLength`.
    private let notifyChunkLength: Int
    private var beacon = Data()
    private var isRunning = false
    private var generation = 0

    // The one browser that may be connected to us.
    private var isConnected = false
    private var isSubscribed = false
    private var inbound = BluetoothWire.Reassembler()
    private var token: PeerToken?
    private var hasIncomingInvite = false
    /// True while the engine has a link over this connection (`route == .asPeripheral` in BluetoothTransport).
    private var isLinked = false
    private var serial = 0

    init(notifyChunkLength: Int) {
        self.notifyChunkLength = max(notifyChunkLength, 2)
        readStandardInput()
    }

    // MARK: Transport

    func start(_ advertisement: LocalAdvertisement) {
        beacon = BluetoothWire.beacon(advertisement)
        isRunning = true
    }

    func stop() {
        if isLinked { notify(BluetoothWire.frame(.close)) }
        isRunning = false
        generation += 1
        forgetBrowser()
    }

    /// A browser cannot be found or invited: it never announces itself. Same answer as for a phone that left.
    func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {
        emitLater(.disconnected(peer))
    }

    func respondToInvitation(from peer: PeerToken, accept: Bool) {
        guard peer == token, hasIncomingInvite, isSubscribed else {
            if accept { emitLater(.disconnected(peer)) }
            return
        }
        hasIncomingInvite = false
        guard accept else {
            notify(BluetoothWire.frame(.decline))
            return
        }
        isLinked = true
        notify(BluetoothWire.frame(.accept))
        emitLater(.connected(peer))
    }

    func send(_ data: Data, to peer: PeerToken) throws {
        guard peer == token, isLinked, isSubscribed else { throw TransportError.notConnected }
        notify(BluetoothWire.frame(.data, data))
    }

    func disconnect(_ peer: PeerToken) {
        guard peer == token, isLinked else { return }
        isLinked = false
        notify(BluetoothWire.frame(.close))
    }

    // MARK: Lines from the browser

    private func readStandardInput() {
        // A plain background thread that blocks on stdin and hands each line to the main thread.
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(line) } }
            }
            // stdin closed: the test that started us has gone away.
            DispatchQueue.main.async { exit(0) }
        }
        thread.start()
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "GATT", parts.count >= 2 else { return }
        switch parts[1] {
        case "connect":
            // A new connection replaces any earlier one we were not told about.
            browserLeft()
            isConnected = true
        case "subscribe":
            guard isConnected else { return }
            isSubscribed = true
            output("GATT subscribed")
        case "read":
            output("GATT beacon \(beacon.base64EncodedString())")
        case "write":
            output(write(parts.count > 2 ? Data(base64Encoded: parts[2]) : nil))
        case "disconnect":
            browserLeft()
        default:
            break
        }
    }

    /// Mirrors `peripheralManager(_:didReceiveWrite:)` for one write request.
    private func write(_ value: Data?) -> String {
        guard isRunning else { return "GATT write-error writeNotPermitted" }
        guard let value else { return "GATT write-error requestNotSupported" }
        guard isSubscribed else { return "GATT write-error insufficientAuthorization" }
        let limit = isLinked ? BluetoothWire.maxFrameLength : BluetoothWire.maxUnlinkedFrameLength
        do {
            if let frame = try inbound.append(value, limit: limit) { frameReceived(frame) }
        } catch {
            inbound.reset()
            return "GATT write-error invalidAttributeValueLength"
        }
        return "GATT write-ok"
    }

    /// Mirrors `frameReceived(_:fromCentral:)`.
    private func frameReceived(_ frame: Data) {
        guard let (kind, body) = BluetoothWire.parseFrame(frame) else { return }
        switch kind {
        case .invite:
            guard isSubscribed, let (_, context) = BluetoothWire.parseInviteBody(body) else { return }
            let token = self.token ?? {
                serial += 1
                return PeerToken(rawValue: "pipe#\(serial)")
            }()
            self.token = token
            hasIncomingInvite = true
            emit(.invited(by: token, context: context))
        case .data:
            guard isLinked, let token else { return }
            emit(.received(body, from: token))
        case .close:
            guard let token else { return }
            if isLinked {
                isLinked = false
                emit(.disconnected(token))
            } else {
                hasIncomingInvite = false
            }
        case .accept, .decline:
            break
        }
    }

    /// Mirrors `dropCentral`: the browser's Bluetooth connection is gone.
    private func browserLeft() {
        let hadLink = isLinked
        let token = self.token
        forgetBrowser()
        if hadLink, let token { emit(.disconnected(token)) }
    }

    private func forgetBrowser() {
        isConnected = false
        isSubscribed = false
        isLinked = false
        hasIncomingInvite = false
        token = nil
        inbound.reset()
    }

    // MARK: Output

    private func notify(_ frame: Data) {
        // Notifications only reach a browser that is listening, as with Core Bluetooth.
        guard isSubscribed else { return }
        for chunk in BluetoothWire.chunks(of: frame, maxChunkLength: notifyChunkLength) {
            output("GATT notify \(chunk.base64EncodedString())")
        }
    }

    private func output(_ line: String) { print(line) }

    private func emit(_ event: TransportEvent) { eventHandler?(event) }

    private func emitLater(_ event: TransportEvent) {
        let generation = generation
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.generation == generation else { return }
                self.emit(event)
            }
        }
    }
}
#endif
