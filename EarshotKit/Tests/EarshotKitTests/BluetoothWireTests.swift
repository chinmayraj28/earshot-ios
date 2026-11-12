import Foundation
import Testing
@testable import EarshotKit

@Suite("Bluetooth wire format")
struct BluetoothWireTests {
    private func advertisement(name: String = "Maya Okafor") -> LocalAdvertisement {
        LocalAdvertisement(displayName: name, nonce: Data([1, 2, 3, 4, 5, 6, 7, 8]),
                           tag: Data([9, 8, 7, 6, 5, 4, 3, 2]), isVisible: true)
    }

    @Test func beaconRoundTrips() {
        let original = advertisement(name: "Zoë 🌙")
        #expect(BluetoothWire.parseBeacon(BluetoothWire.beacon(original)) == original)
    }

    @Test func beaconRejectsGarbage() {
        #expect(BluetoothWire.parseBeacon(Data()) == nil)
        #expect(BluetoothWire.parseBeacon(Data([2, 0, 0])) == nil, "unknown version")
        #expect(BluetoothWire.parseBeacon(Data([1, 200, 1, 2])) == nil, "length runs past the end")
        #expect(BluetoothWire.parseBeacon(Data([1, 0, 0, 0xFF, 0xFE])) == nil, "name is not UTF-8")
        let tooLong = Data([1, 0, 0]) + Data(repeating: 65, count: Limits.maxNameBytes + 1)
        #expect(BluetoothWire.parseBeacon(tooLong) == nil)
    }

    @Test func inviteCarriesNonceAndContext() throws {
        let body = BluetoothWire.inviteBody(nonce: Data([7, 7, 7]), context: Data("ctx".utf8))
        let frame = BluetoothWire.frame(.invite, body)
        let parsed = try #require(BluetoothWire.parseFrame(frame))
        #expect(parsed.kind == .invite)
        let invite = try #require(BluetoothWire.parseInviteBody(parsed.body))
        #expect(invite.nonce == Data([7, 7, 7]))
        #expect(invite.context == Data("ctx".utf8))
        #expect(BluetoothWire.parseInviteBody(Data([9, 1])) == nil)
        #expect(BluetoothWire.parseFrame(Data([99, 1])) == nil, "unknown frame kind")
        #expect(BluetoothWire.parseFrame(Data()) == nil)
    }

    @Test(arguments: [0, 1, 19, 20, 21, 181, 5000], [20, 23, 182, 512])
    func chunksReassemble(length: Int, chunkLength: Int) throws {
        let frame = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
        let chunks = BluetoothWire.chunks(of: frame, maxChunkLength: chunkLength)
        #expect(chunks.allSatisfy { $0.count <= chunkLength && !$0.isEmpty })
        var reassembler = BluetoothWire.Reassembler()
        var result: Data?
        for (index, chunk) in chunks.enumerated() {
            let out = try reassembler.append(chunk)
            if index < chunks.count - 1 { #expect(out == nil) } else { result = out }
        }
        #expect(result == frame)
    }

    @Test func reassemblerHandlesBackToBackFrames() throws {
        var reassembler = BluetoothWire.Reassembler()
        for text in ["first", "second message", ""] {
            var out: Data?
            for chunk in BluetoothWire.chunks(of: Data(text.utf8), maxChunkLength: 4) { out = try reassembler.append(chunk) }
            #expect(out == Data(text.utf8))
        }
    }

    @Test func reassemblerRefusesEndlessFrames() {
        var reassembler = BluetoothWire.Reassembler()
        let piece = Data([0]) + Data(repeating: 1, count: 500)
        #expect(throws: BluetoothWire.WireError.self) {
            for _ in 0...(BluetoothWire.maxFrameLength / 500) { _ = try reassembler.append(piece) }
        }
        // And it starts clean afterwards.
        #expect((try? reassembler.append(Data([1, 42]))) == Data([42]))
    }

    @Test func reassemblerRefusesBadMarkers() {
        var reassembler = BluetoothWire.Reassembler()
        #expect(throws: BluetoothWire.WireError.self) { _ = try reassembler.append(Data([7, 1, 2])) }
        #expect(throws: BluetoothWire.WireError.self) { _ = try reassembler.append(Data()) }
    }

    @Test func problemsThatFixThemselves() {
        #expect(TransportProblem.bluetoothOff.recoversByItself)
        #expect(TransportProblem.bluetoothDenied.recoversByItself)
        #expect(!TransportProblem.bluetoothUnsupported.recoversByItself)
        #expect(!TransportProblem.failedToStart("x").recoversByItself)
    }
}

/// A radio that does nothing by itself; the test plays the part of Bluetooth.
@MainActor
private final class ScriptedTransport: Transport {
    var eventHandler: ((TransportEvent) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start(_ advertisement: LocalAdvertisement) { starts += 1 }
    func stop() { stops += 1 }
    func invite(_ peer: PeerToken, context: Data, timeout: TimeInterval) {}
    func respondToInvitation(from peer: PeerToken, accept: Bool) {}
    func send(_ data: Data, to peer: PeerToken) throws { throw TransportError.notConnected }
    func disconnect(_ peer: PeerToken) {}
}

@Suite("Bluetooth availability")
@MainActor
struct BluetoothAvailabilityTests {
    private func makeMessenger() -> (Messenger, ScriptedTransport) {
        let transport = ScriptedTransport()
        let messenger = Messenger(transport: transport, persistence: InMemoryPersistence(),
                                  identityStore: InMemoryIdentityStore())
        messenger.completeOnboarding(displayName: "Alex")
        messenger.start()
        return (messenger, transport)
    }

    @Test(arguments: [TransportProblem.bluetoothOff, .bluetoothDenied])
    func comesBackWhenBluetoothDoes(problem: TransportProblem) {
        let (messenger, transport) = makeMessenger()
        #expect(messenger.availability == .on)

        transport.eventHandler?(.unavailable(problem))
        #expect(messenger.availability == .unavailable(problem))
        #expect(transport.stops == 0, "the radio layer must keep watching for Bluetooth to return")

        transport.eventHandler?(.ready)
        #expect(messenger.availability == .on)
        #expect(transport.starts == 2)
    }

    @Test func givesUpWithoutBluetoothHardware() {
        let (messenger, transport) = makeMessenger()
        transport.eventHandler?(.unavailable(.bluetoothUnsupported))
        #expect(messenger.availability == .unavailable(.bluetoothUnsupported))
        #expect(transport.stops == 1)
        transport.eventHandler?(.ready)
        #expect(messenger.availability == .unavailable(.bluetoothUnsupported))
    }
}
