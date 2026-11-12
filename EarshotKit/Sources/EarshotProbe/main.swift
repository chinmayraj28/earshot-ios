// earshot-probe: a headless Earshot peer for the Mac.
//
// It runs the same engine and the same radio layers as the app, so it can stand in
// for a second phone:
//
//   swift run earshot-probe --name "Probe" --echo                 (Wi-Fi/Multipeer: pairs with the iOS Simulator)
//   swift run earshot-probe --name "Probe" --echo --bluetooth     (Bluetooth LE: pairs with a real iPhone)
//   swift run earshot-probe --name "Caller" --invite "Probe" --send "hello" --exit-after-delivery
//
// It accepts every incoming request, prints what happens, and (with --echo)
// replies to each message with "Echo: <text>".

import EarshotKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

var name = "Probe"
var echo = false
var inviteName: String?
var textToSend: String?
var exitAfterDelivery = false
var timeout: Double?
var radio = Radio.multipeer

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--name": name = arguments.next() ?? name
    case "--echo": echo = true
    case "--bluetooth": radio = .bluetooth
    case "--invite": inviteName = arguments.next()
    case "--send": textToSend = arguments.next()
    case "--exit-after-delivery": exitAfterDelivery = true
    case "--timeout": timeout = arguments.next().flatMap(Double.init)
    default:
        print("unknown argument \(argument)")
        exit(64)
    }
}

let messenger = Messenger.ephemeral(radio: radio)
messenger.completeOnboarding(displayName: name)

messenger.onEvent = { event in
    switch event {
    case .requestReceived(let request):
        print("REQUEST from \(request.displayName) – accepting")
        messenger.accept(request)
    case .connected(let id):
        let who = messenger.contact(id)?.displayName ?? "?"
        print("CONNECTED \(who) code \(messenger.safetyCode(for: id) ?? "-")")
        if let textToSend {
            messenger.send(textToSend, to: id)
            print("SENT \(textToSend)")
        }
    case .messageReceived(let id, let message):
        print("RECEIVED \(message.text)")
        if echo { messenger.send("Echo: \(message.text)", to: id) }
    }
}

messenger.start()
print("STARTED as \(name) over \(radio)")

var seen: Set<PeerToken> = []
var invited: Set<PeerToken> = []
var reportedDelivered: Set<UUID> = []
var lastAvailability = messenger.availability

let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    MainActor.assumeIsolated {
        if messenger.availability != lastAvailability {
            lastAvailability = messenger.availability
            print("AVAILABILITY \(messenger.availability)")
        }
        for peer in messenger.nearbyPeers where !seen.contains(peer.id) {
            seen.insert(peer.id)
            print("FOUND \(peer.displayName)")
        }
        if let inviteName {
            for peer in messenger.nearbyPeers where peer.displayName == inviteName && !invited.contains(peer.id) {
                invited.insert(peer.id)
                print("INVITING \(peer.displayName)")
                messenger.connect(to: peer)
            }
        }
        for request in messenger.requests {
            if case .failed(let failure) = request.state {
                print("REQUEST FAILED \(failure)")
                messenger.dismiss(request)
            }
        }
        for contact in messenger.contacts {
            for message in messenger.messages(for: contact.id)
            where message.direction == .outgoing && !reportedDelivered.contains(message.id) {
                if message.status == .delivered {
                    reportedDelivered.insert(message.id)
                    print("DELIVERED \(message.text)")
                    if exitAfterDelivery {
                        messenger.stop()
                        exit(0)
                    }
                } else if message.status == .failed {
                    reportedDelivered.insert(message.id)
                    print("FAILED \(message.text)")
                }
            }
        }
    }
}
_ = timer

if let timeout {
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        print("TIMEOUT after \(timeout)s")
        exit(2)
    }
}

RunLoop.main.run()
