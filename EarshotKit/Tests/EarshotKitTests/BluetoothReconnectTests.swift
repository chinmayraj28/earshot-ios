@preconcurrency import CoreBluetooth
import Foundation
import Testing
@testable import EarshotKit

@Suite("Bluetooth reconnect policy")
struct ReconnectPolicyTests {
    private let tom = UUID()
    private let stranger = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func strangersAreNotChased() {
        var policy = ReconnectPolicy()
        #expect(policy.decide(stranger, .linkLost, at: start) == .giveUp)
        #expect(policy.decide(stranger, .connectFailed, at: start) == .giveUp)
        #expect(policy.decide(stranger, .systemReconnecting, at: start) == .giveUp)
        #expect(!policy.isRemembered(stranger))
    }

    @Test func aHealthyLinkIsWaitedForRightAwayEveryTimeItWalksOff() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        var now = start
        for _ in 0..<50 {
            now += 3_600 // linked for an hour, then out of range
            #expect(policy.decide(tom, .linkLost, at: now) == .connect(after: 0))
            now += 600 // back ten minutes later
            policy.cameBack(tom, at: now)
            policy.linkUp(tom, at: now + 2)
        }
        #expect(policy.quickFailures(tom) == 0)
    }

    @Test func iOSReconnectingAfterAHealthyLinkIsOnlyTracked() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(policy.decide(tom, .systemReconnecting, at: at(120)) == .waitForSystem)
        #expect(policy.isRemembered(tom))
    }

    @Test func backOffDoublesToACap() {
        #expect(ReconnectPolicy.retryDelay(afterQuickFailures: 0) == 0)
        let delays = (1...10).map { ReconnectPolicy.retryDelay(afterQuickFailures: $0) }
        #expect(delays == [4, 8, 16, 32, 64, 128, 256, 300, 300, 300])
        #expect(ReconnectPolicy.retryDelay(afterQuickFailures: 10_000) == 300, "no overflow")
    }

    /// A peer that links and then fails at once (always failing the handshake, or a flaky
    /// range edge) must not make both phones reconnect in a tight loop.
    @Test func aPhoneThatKeepsFailingIsBackedOff() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        var now = start
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            now += 5 // connects, links, and drops within seconds
            policy.cameBack(tom, at: now)
            policy.linkUp(tom, at: now + 1)
            guard case .connect(let delay) = policy.decide(tom, .linkLost, at: now + 3) else {
                Issue.record("expected a delayed reconnect")
                return
            }
            delays.append(delay)
            now += delay
        }
        #expect(delays == [4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(policy.isRemembered(tom), "backed off, never given up")
    }

    @Test func iOSOwnReconnectIsOverruledWhileBackingOff() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(policy.decide(tom, .systemReconnecting, at: at(10)) == .connect(after: 4),
                "dropped 10 s after coming up: stop iOS reconnecting at once and wait")
    }

    @Test func failedAttemptsBackOffToo() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(policy.decide(tom, .linkLost, at: at(3_600)) == .connect(after: 0))
        #expect(policy.decide(tom, .connectFailed, at: at(3_700)) == .connect(after: 4))
        #expect(policy.decide(tom, .setupFailed, at: at(3_800)) == .connect(after: 8))
    }

    @Test func aConnectionThatStaysUpResetsTheBackOff() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        _ = policy.decide(tom, .linkLost, at: at(5))
        _ = policy.decide(tom, .setupFailed, at: at(20))
        #expect(policy.quickFailures(tom) == 2)
        policy.cameBack(tom, at: at(100))
        #expect(policy.decide(tom, .linkLost, at: at(100 + ReconnectPolicy.stableAfter)) == .connect(after: 0))
        #expect(policy.quickFailures(tom) == 0)
    }

    @Test func lettingGoOnPurposeForgetsThePhone() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(policy.decide(tom, .dropped, at: start) == .giveUp)
        #expect(!policy.isRemembered(tom))
        #expect(policy.decide(tom, .linkLost, at: start) == .giveUp)
    }

    @Test func forgetStopsTheChase() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        policy.forget(tom)
        #expect(policy.decide(tom, .linkLost, at: at(3_600)) == .giveUp)
    }

    @Test func aPhoneThatCameBackButWasNotLinkedBecomesUnused() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(!policy.isUnused(tom, at: at(10_000)), "never came back: still wanted")
        let back = at(600)
        policy.cameBack(tom, at: back)
        #expect(!policy.isUnused(tom, at: back.addingTimeInterval(ReconnectPolicy.unusedGrace - 1)))
        #expect(policy.isUnused(tom, at: back.addingTimeInterval(ReconnectPolicy.unusedGrace)))
        // Linked after coming back: in use.
        policy.linkUp(tom, at: back.addingTimeInterval(3))
        #expect(!policy.isUnused(tom, at: back.addingTimeInterval(10_000)))
    }

    /// A blocked contact who is away cannot be named by the transport (it only knows
    /// addresses). When they come back no link opens, so they are let go after the grace.
    @Test func aBlockedContactWhoReturnsIsLetGoAndNotReAdded() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        #expect(policy.decide(tom, .linkLost, at: at(3_600)) == .connect(after: 0))
        policy.cameBack(tom, at: at(7_200))
        let later = at(7_200 + ReconnectPolicy.unusedGrace)
        #expect(policy.isUnused(tom, at: later))
        policy.forget(tom) // what the transport does when `isUnused` is true
        #expect(policy.decide(tom, .linkLost, at: later + 60) == .giveUp)
        #expect(!policy.isRemembered(tom), "only a new link adds a phone again")
    }

    @Test func restoredConnectionsAreProvisionalUntilALinkOpens() {
        var policy = ReconnectPolicy()
        #expect(policy.rememberProvisionally(stranger, at: start) == nil)
        #expect(policy.isRemembered(stranger) && policy.isProvisional(stranger))
        // It comes back, nobody links with it: let go after the grace.
        policy.cameBack(stranger, at: at(30))
        #expect(policy.isUnused(stranger, at: at(30 + ReconnectPolicy.unusedGrace)))
        // A contact restored the same way is confirmed by its link.
        #expect(policy.rememberProvisionally(tom, at: start) == nil)
        policy.cameBack(tom, at: at(30))
        policy.linkUp(tom, at: at(32))
        #expect(!policy.isProvisional(tom))
        #expect(!policy.isUnused(tom, at: at(10_000)))
        // Restoring never downgrades a phone that is already confirmed.
        #expect(policy.rememberProvisionally(tom, at: at(40)) == nil)
        #expect(!policy.isProvisional(tom))
    }

    @Test func provisionalPhonesNeverPushOutConfirmedOnes() {
        var policy = ReconnectPolicy()
        let contacts = (0..<ReconnectPolicy.maxRemembered).map { _ in UUID() }
        for (index, contact) in contacts.enumerated() { policy.linkUp(contact, at: at(Double(index))) }
        // The list is full of confirmed phones: a restored one makes room by leaving itself.
        #expect(policy.rememberProvisionally(stranger, at: at(100)) == stranger)
        #expect(!policy.isRemembered(stranger))
        #expect(contacts.allSatisfy(policy.isRemembered))
        // With provisional phones present, a new confirmed phone pushes out a provisional one first.
        policy.forget(contacts[0])
        #expect(policy.rememberProvisionally(stranger, at: at(200)) == nil)
        let newContact = UUID()
        #expect(policy.linkUp(newContact, at: at(300)) == stranger)
    }

    @Test func rememberedPhonesAreCappedOldestFirst() {
        var policy = ReconnectPolicy()
        let phones = (0..<ReconnectPolicy.maxRemembered).map { _ in UUID() }
        for (index, phone) in phones.enumerated() {
            #expect(policy.linkUp(phone, at: at(Double(index))) == nil)
        }
        // Linking the oldest again makes the second oldest the one to go.
        policy.linkUp(phones[0], at: at(100))
        let newcomer = UUID()
        #expect(policy.linkUp(newcomer, at: at(200)) == phones[1])
        #expect(policy.remembered.count == ReconnectPolicy.maxRemembered)
        #expect(policy.isRemembered(newcomer) && policy.isRemembered(phones[0]) && !policy.isRemembered(phones[1]))
    }

    @Test func forgetAllClearsEverything() {
        var policy = ReconnectPolicy()
        policy.linkUp(tom, at: start)
        policy.rememberProvisionally(stranger, at: start)
        policy.forgetAll()
        #expect(policy.remembered.isEmpty)
    }
}

@Suite("Bluetooth transport decisions")
struct LinkTriageTests {
    @Test func aDropIsCleanedUpAndHandedToThePolicy() {
        #expect(LinkTriage.onDisconnect(cancelledRecently: false, alreadyWaiting: false,
                                        remembered: true, isReconnecting: false) == .drop(.linkLost))
        #expect(LinkTriage.onDisconnect(cancelledRecently: false, alreadyWaiting: false,
                                        remembered: false, isReconnecting: false) == .drop(.linkLost))
    }

    @Test func whenIOSReconnectsAKnownPhoneNoSecondRequestIsMade() {
        #expect(LinkTriage.onDisconnect(cancelledRecently: false, alreadyWaiting: false,
                                        remembered: true, isReconnecting: true) == .drop(.systemReconnecting))
    }

    @Test func iOSIsStoppedFromReconnectingAPhoneWeNoLongerWant() {
        #expect(LinkTriage.onDisconnect(cancelledRecently: false, alreadyWaiting: false,
                                        remembered: false, isReconnecting: true) == .cancelSystemReconnectAndDrop)
    }

    @Test func theSameDropReportedTwiceOrOurOwnCancelIsIgnored() {
        for remembered in [true, false] {
            for reconnecting in [true, false] {
                #expect(LinkTriage.onDisconnect(cancelledRecently: true, alreadyWaiting: false,
                                                remembered: remembered, isReconnecting: reconnecting) == .ignore)
                #expect(LinkTriage.onDisconnect(cancelledRecently: false, alreadyWaiting: true,
                                                remembered: remembered, isReconnecting: reconnecting) == .ignore)
            }
        }
    }

    @Test func restoredConnectionsAreTakenOverNotDuplicated() {
        #expect(LinkTriage.onRestore(.connecting, isRunning: true) == .takeOver)
        #expect(LinkTriage.onRestore(.connected, isRunning: true) == .reopen)
        #expect(LinkTriage.onRestore(.disconnected, isRunning: true) == .cancel)
        #expect(LinkTriage.onRestore(.disconnecting, isRunning: true) == .cancel)
        for state in [CBPeripheralState.connecting, .connected, .disconnected] {
            #expect(LinkTriage.onRestore(state, isRunning: false) == .cancel)
        }
    }

    @Test func forgettingAPhoneCoversEveryAddressItUsed() {
        let current = UUID(), earlier = UUID(), someoneElse = UUID()
        let nonce = Data([1, 2, 3]), other = Data([9])
        let known = [current: nonce, earlier: nonce, someoneElse: other]
        #expect(LinkTriage.addresses(of: current, nonce: nonce, nonceByAddress: known) == [current, earlier])
        #expect(LinkTriage.addresses(of: nil, nonce: nonce, nonceByAddress: known) == [current, earlier])
        #expect(LinkTriage.addresses(of: current, nonce: nil, nonceByAddress: known) == [current])
        #expect(LinkTriage.addresses(of: nil, nonce: nil, nonceByAddress: known).isEmpty)
    }
}

@Suite("Bluetooth transport forget hooks")
@MainActor
struct TransportForgetTests {
    /// Radios that never reconnect by themselves get the hooks for free.
    @Test func otherRadiosNeedNoChange() {
        let world = LoopbackHub()
        let transport: Transport = world.makeTransport()
        transport.forget(PeerToken(rawValue: "x"))
        transport.forgetAllPeers()
    }

    /// Without Bluetooth running, the hooks and diagnostics are safe no-ops.
    @Test func bluetoothHooksAreSafeBeforeStart() {
        let transport = BluetoothTransport()
        transport.forget(PeerToken(rawValue: "bt#1"))
        transport.forgetAllPeers()
        transport.disconnect(PeerToken(rawValue: "bt#1"))
        #expect(transport.diagnostics().isEmpty)
    }
}

@Suite("Bluetooth link diagnostics")
struct LinkEventLogTests {
    private func event(_ index: Int) -> LinkEvent {
        LinkEvent(date: Date(timeIntervalSinceReferenceDate: Double(index)), kind: .signal,
                  peer: "ab12", rssi: -index, appState: .foreground)
    }

    @Test func keepsEverythingBelowCapacityInOrder() {
        var log = LinkEventLog(capacity: 5)
        (0..<3).forEach { log.append(event($0)) }
        #expect(log.events.map(\.rssi) == [0, -1, -2])
    }

    @Test func dropsTheOldestWhenFull() {
        var log = LinkEventLog(capacity: 5)
        (0..<12).forEach { log.append(event($0)) }
        #expect(log.count == 5)
        #expect(log.events.map(\.rssi) == [-7, -8, -9, -10, -11])
    }

    @Test func defaultCapacityIs500() {
        var log = LinkEventLog()
        (0..<1_234).forEach { log.append(event($0)) }
        #expect(log.count == 500)
        #expect(log.events.first?.rssi == -734)
        #expect(log.events.last?.rssi == -1_233)
        log.removeAll()
        #expect(log.events.isEmpty)
        log.append(event(1))
        #expect(log.events.count == 1)
    }

    @Test func peerLabelIsShortAndNotTheWholeIdentifier() throws {
        let id = try #require(UUID(uuidString: "AB12CD34-0000-0000-0000-000000000000"))
        #expect(LinkEvent.label(for: id) == "ab12")
        #expect(event(60).summary == "signal peer=ab12 rssi=-60 app=foreground")
        let noSignal = LinkEvent(date: Date(), kind: .linkUp, peer: "ab12", rssi: nil, appState: .background)
        #expect(noSignal.summary == "linkUp peer=ab12 app=background")
    }
}

@Suite("Bluetooth outgoing queue limit")
struct OutgoingBudgetTests {
    private func chunk(last: Bool, size: Int = 10) -> Data {
        Data([last ? 1 : 0]) + Data(repeating: 7, count: size - 1)
    }

    @Test func admitsUpToTheLimitAndRefusesBeyondWithoutChangingAnything() {
        var budget = OutgoingBudget()
        let nearlyFull = budget.admit(OutgoingBudget.limit - 10)
        let full = budget.admit(10)
        let over = budget.admit(1)
        #expect(nearlyFull && full && !over)
        #expect(budget.bytes == OutgoingBudget.limit, "a refused frame is not counted")
        budget.sent(100)
        let roomAgain = budget.admit(100)
        #expect(roomAgain)
    }

    @Test func controlFramesAlwaysGoAndSendingNeverGoesNegative() {
        var budget = OutgoingBudget()
        let admitted = budget.admit(OutgoingBudget.limit)
        #expect(admitted)
        budget.force(6) // "close" must still go out
        #expect(budget.bytes == OutgoingBudget.limit + 6)
        budget.sent(10_000_000)
        #expect(budget.bytes == 0)
        budget.reset(to: 42)
        #expect(budget.bytes == 42)
    }

    @Test func limitCoversTheLargestHonestBurst() {
        // 60 waiting texts of 2,000 three-byte characters, one relay round, relay control
        // messages and one photo's pieces in flight (see `OutgoingBudget`).
        let honest = 60 * (2_000 * 3 + 200) + 72 * 1_024 + 60 * 1_024 + 19 * 1_024
        #expect(honest < OutgoingBudget.limit)
        #expect(Double(OutgoingBudget.limit) / Double(honest) > 1.5)
    }

    @Test func theFrameInProgressIsFinishedAndTheRestDropped() {
        let queue = [chunk(last: false), chunk(last: true), chunk(last: false), chunk(last: true), chunk(last: true)]
        #expect(OutgoingBudget.chunksFinishingCurrentFrame(queue, midFrame: true) == 2)
        #expect(OutgoingBudget.chunksFinishingCurrentFrame(queue, midFrame: false) == 0,
                "between frames nothing has to be finished")
        #expect(OutgoingBudget.chunksFinishingCurrentFrame([chunk(last: true)], midFrame: true) == 1)
        #expect(OutgoingBudget.chunksFinishingCurrentFrame([], midFrame: true) == 0)
        // A frame whose end is not queued yet is kept whole (its end will never be sent,
        // but nothing after it was queued either).
        #expect(OutgoingBudget.chunksFinishingCurrentFrame([chunk(last: false), chunk(last: false)], midFrame: true) == 2)
    }

    /// The chunks kept and the ones dropped line up with real frame boundaries.
    @Test func trimmingAtTheBoundaryLeavesWholeFrames() throws {
        let first = Data(repeating: 1, count: 50), second = Data(repeating: 2, count: 50)
        var queue = BluetoothWire.chunks(of: first, maxChunkLength: 20) + BluetoothWire.chunks(of: second, maxChunkLength: 20)
        // The first chunk of `first` is already on its way.
        let inFlight = queue.removeFirst()
        let keep = OutgoingBudget.chunksFinishingCurrentFrame(queue, midFrame: inFlight.first == 0)
        var reassembler = BluetoothWire.Reassembler()
        var frames: [Data] = []
        for piece in [inFlight] + queue.prefix(keep) {
            if let frame = try reassembler.append(piece) { frames.append(frame) }
        }
        #expect(frames == [first], "the receiver gets the whole first frame and no part of the second")
    }
}
