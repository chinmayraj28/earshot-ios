import Foundation
import Testing
@testable import EarshotKit

@MainActor
struct Phone {
    let messenger: Messenger
    let transport: LoopbackTransport
    let persistence: InMemoryPersistence
    let identityStore: InMemoryIdentityStore
    var token: PeerToken { transport.token }
}

extension Messenger.Configuration {
    /// Short timers so the suite runs in a couple of seconds.
    static var fast: Messenger.Configuration {
        var c = Messenger.Configuration()
        c.ackTimeout = .milliseconds(150)
        c.handshakeTimeout = .milliseconds(200)
        c.inviteTimeout = 4
        c.reconnectDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        c.tieBreakDelay = .milliseconds(40)
        c.steadyRetryDelay = .milliseconds(80)
        return c
    }
}

@MainActor
func makePhone(_ hub: LoopbackHub, _ name: String, persistence: InMemoryPersistence = InMemoryPersistence(),
               identityStore: InMemoryIdentityStore = InMemoryIdentityStore(), start: Bool = true,
               configuration: Messenger.Configuration = .fast) -> Phone {
    let transport = hub.makeTransport(token: name.lowercased() + "-" + UUID().uuidString.prefix(4))
    let messenger = Messenger(transport: transport, persistence: persistence, identityStore: identityStore,
                              configuration: configuration)
    messenger.completeOnboarding(displayName: name)
    if start { messenger.start() }
    return Phone(messenger: messenger, transport: transport, persistence: persistence, identityStore: identityStore)
}

/// Polls until the condition holds. Fails the test if it never does.
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(3), _ condition: () -> Bool,
               sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting until \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// Takes two phones through the full request → accept → secure link flow.
@MainActor
@discardableResult
func befriend(_ a: Phone, _ b: Phone) throws -> (aSeesB: ContactID, bSeesA: ContactID) {
    let peer = try #require(a.messenger.nearbyPeers.first { $0.id == b.token })
    a.messenger.connect(to: peer)
    let request = try #require(b.messenger.requests.first { $0.id == a.token })
    b.messenger.accept(request)
    let aSeesB = try #require(a.messenger.contacts.first { $0.identityKey == b.messenger.identityKey }).id
    let bSeesA = try #require(b.messenger.contacts.first { $0.identityKey == a.messenger.identityKey }).id
    a.messenger.requests.forEach(a.messenger.dismiss)
    b.messenger.requests.forEach(b.messenger.dismiss)
    return (aSeesB, bSeesA)
}
