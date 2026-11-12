import Foundation
import Testing
@testable import EarshotKit

@MainActor
@Suite struct DiscoveryAndConsentTests {
    @Test func phonesSeeEachOtherByName() {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        #expect(a.messenger.nearbyPeers.map(\.displayName) == ["Blake"])
        #expect(b.messenger.nearbyPeers.map(\.displayName) == ["Alex"])
        #expect(a.messenger.nearbyPeers[0].contactID == nil)
        #expect(a.messenger.contacts.isEmpty)
    }

    @Test func nothingHappensBeforeOnboarding() {
        let hub = LoopbackHub()
        let transport = hub.makeTransport()
        let fresh = Messenger(transport: transport, persistence: InMemoryPersistence(), identityStore: InMemoryIdentityStore())
        fresh.start()
        #expect(fresh.availability == .off)
        let b = makePhone(hub, "Blake")
        #expect(b.messenger.nearbyPeers.isEmpty)
    }

    @Test func hiddenPhoneIsNotAnnouncedButStillFindsOthers() {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex", start: false)
        a.messenger.setVisible(false)
        a.messenger.start()
        let b = makePhone(hub, "Blake")
        #expect(b.messenger.nearbyPeers.isEmpty)
        #expect(a.messenger.nearbyPeers.map(\.displayName) == ["Blake"])
    }

    @Test func conversationNeedsConsentFromBothPeople() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        a.messenger.connect(to: a.messenger.nearbyPeers[0])

        // Alex is waiting; Blake has a prompt; nobody is a contact yet.
        #expect(a.messenger.requests.map(\.state) == [.waiting])
        let request = try #require(b.messenger.requests.first)
        #expect(request.direction == .incoming)
        #expect(request.displayName == "Alex")
        #expect(request.state == .pending)
        #expect(a.messenger.contacts.isEmpty && b.messenger.contacts.isEmpty)

        b.messenger.accept(request)
        let blake = try #require(a.messenger.contacts.first)
        let alex = try #require(b.messenger.contacts.first)
        #expect(blake.displayName == "Blake" && alex.displayName == "Alex")
        #expect(blake.identityKey == b.messenger.identityKey)
        #expect(a.messenger.requests.map(\.state) == [.connected(blake.id)])
        #expect(b.messenger.requests.map(\.state) == [.connected(alex.id)])
        #expect(a.messenger.linkState(for: blake.id) == .connected)
        #expect(b.messenger.linkState(for: alex.id) == .connected)
        #expect(a.messenger.safetyCode(for: blake.id) == b.messenger.safetyCode(for: alex.id))
        #expect(a.messenger.nearbyPeers.first?.contactID == blake.id)
    }

    @Test func declinedRequestCreatesNothingAndIsNotRepeated() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        b.messenger.decline(try #require(b.messenger.requests.first))

        #expect(a.messenger.requests.map(\.state) == [.failed(.noAnswer)])
        #expect(b.messenger.requests.isEmpty)
        #expect(a.messenger.contacts.isEmpty && b.messenger.contacts.isEmpty)

        // Alex tries again: Blake is not prompted a second time in this session.
        a.messenger.dismiss(a.messenger.requests[0])
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        #expect(b.messenger.requests.isEmpty)
        #expect(a.messenger.requests.map(\.state) == [.failed(.noAnswer)])
    }

    @Test func unansweredRequestTimesOut() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        #expect(b.messenger.requests.count == 1)
        // The prompt disappears a little before the radio-level timeout (4 s − 3 s here).
        await waitUntil("prompt expires") { b.messenger.requests.isEmpty }
        await waitUntil("sender is told") { a.messenger.requests.map(\.state) == [.failed(.noAnswer)] }
        #expect(a.messenger.contacts.isEmpty && b.messenger.contacts.isEmpty)
    }

    @Test func cancellingARequestWithdrawsIt() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        a.messenger.dismiss(a.messenger.requests[0])
        #expect(a.messenger.requests.isEmpty)
        // Blake accepting the stale prompt must not create a one-sided contact.
        b.messenger.accept(try #require(b.messenger.requests.first))
        #expect(a.messenger.contacts.isEmpty)
        #expect(b.messenger.contacts.isEmpty)
    }

    @Test func bothTappingConnectAtOnceStillConnects() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        b.messenger.connect(to: b.messenger.nearbyPeers[0])
        #expect(a.messenger.contacts.count == 1 && b.messenger.contacts.count == 1)
        #expect(a.messenger.linkState(for: a.messenger.contacts[0].id) == .connected)
    }

    @Test func simultaneousRadioInvitesResolveToOneLink() async throws {
        // Delivery is delayed, so both invitations are in the air before either arrives.
        let hub = LoopbackHub(latency: .milliseconds(2))
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        await waitUntil("discovery") { !a.messenger.nearbyPeers.isEmpty && !b.messenger.nearbyPeers.isEmpty }
        a.messenger.connect(to: a.messenger.nearbyPeers[0])
        b.messenger.connect(to: b.messenger.nearbyPeers[0])
        await waitUntil("both connected") {
            a.messenger.contacts.count == 1 && b.messenger.contacts.count == 1
                && a.messenger.linkState(for: a.messenger.contacts[0].id) == .connected
                && b.messenger.linkState(for: b.messenger.contacts[0].id) == .connected
        }
        let id = a.messenger.contacts[0].id
        a.messenger.send("hi", to: id)
        await waitUntil("delivered") { a.messenger.messages(for: id).last?.status == .delivered }
    }
}

@MainActor
@Suite struct MessagingTests {
    @Test func messageIsDeliveredAndConfirmed() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        let sent = try #require(a.messenger.send("  Meet by the stairs?  ", to: ids.aSeesB))
        #expect(sent.text == "Meet by the stairs?")
        #expect(a.messenger.messages(for: ids.aSeesB).map(\.status) == [.delivered])

        let received = b.messenger.messages(for: ids.bSeesA)
        #expect(received.map(\.text) == ["Meet by the stairs?"])
        #expect(received[0].direction == .incoming && received[0].id == sent.id)
        #expect(b.messenger.conversations[ids.bSeesA]?.unreadCount == 1)
        #expect(b.messenger.conversationSummaries.first?.unreadCount == 1)

        b.messenger.setActiveConversation(ids.bSeesA)
        #expect(b.messenger.conversations[ids.bSeesA]?.unreadCount == 0)
        a.messenger.send("Still there?", to: ids.aSeesB)
        #expect(b.messenger.conversations[ids.bSeesA]?.unreadCount == 0)
    }

    @Test func emptyAndOversizedMessagesAreRefused() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        #expect(a.messenger.send("   \n ", to: ids.aSeesB) == nil)
        #expect(a.messenger.send(String(repeating: "x", count: Limits.maxMessageLength + 1), to: ids.aSeesB) == nil)
        #expect(a.messenger.send(String(repeating: "x", count: Limits.maxMessageLength), to: ids.aSeesB) != nil)
        #expect(b.messenger.messages(for: ids.bSeesA).count == 1)
        #expect(a.messenger.send("hi", to: ContactID(rawValue: "nobody")) == nil)
    }

    @Test func onlyCiphertextCrossesTheAir() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        var frames: [Data] = []
        hub.intercept = { data, _, _ in frames.append(data); return data }
        let ids = try befriend(a, b)
        a.messenger.send("the secret plan", to: ids.aSeesB)
        #expect(frames.count >= 6)
        for frame in frames {
            #expect(frame.range(of: Data("the secret plan".utf8)) == nil)
            #expect(frame.range(of: Data("Alex".utf8)) == nil)
            #expect(frame.range(of: a.messenger.identityKey) == nil)
        }
    }

    @Test func missingReceiptMarksMessageFailedAndRetryDoesNotDuplicate() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        // Receipts from Blake get lost on the way back.
        hub.intercept = { data, from, _ in from == b.token ? nil : data }
        let sent = try #require(a.messenger.send("hello?", to: ids.aSeesB))
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .sending)
        await waitUntil("marked failed") { a.messenger.messages(for: ids.aSeesB).last?.status == .failed }
        #expect(b.messenger.messages(for: ids.bSeesA).count == 1)

        hub.intercept = nil
        a.messenger.retry(sent.id, in: ids.aSeesB)
        // Frames went missing, so the link's counters no longer line up: it is rebuilt
        // with fresh keys and the message goes through — once.
        await waitUntil("delivered after retry") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).count == 1)
    }

    @Test func messagesWaitWhileOutOfRangeAndSendOnReturn() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        hub.setReachable(false, b.transport)
        #expect(a.messenger.linkState(for: ids.aSeesB) == .outOfRange)
        a.messenger.send("one", to: ids.aSeesB)
        a.messenger.send("two", to: ids.aSeesB)
        #expect(a.messenger.messages(for: ids.aSeesB).map(\.status) == [.waiting, .waiting])

        hub.setReachable(true, b.transport)
        await waitUntil("reconnected and delivered") {
            a.messenger.messages(for: ids.aSeesB).map(\.status) == [.delivered, .delivered]
        }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == ["one", "two"])
        // Saved contacts reconnect without a new prompt on either phone.
        #expect(a.messenger.requests.isEmpty && b.messenger.requests.isEmpty)
        #expect(a.messenger.linkState(for: ids.aSeesB) == .connected)
    }

    @Test func droppedLinkReconnectsAndResendsUnconfirmedMessages() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        hub.intercept = { data, from, _ in from == b.token ? nil : data }
        a.messenger.send("in flight", to: ids.aSeesB)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .sending)

        hub.intercept = nil
        hub.dropConnection(a.transport, b.transport)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .waiting)
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)

        await waitUntil("link restored") { a.messenger.linkState(for: ids.aSeesB) == .connected }
        await waitUntil("delivered") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == ["in flight"])
    }

    @Test func closingTheAppParksMessagesAndTellsThePeer() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        b.messenger.stop()
        #expect(b.messenger.availability == .off)
        #expect(a.messenger.linkState(for: ids.aSeesB) == .outOfRange)
        a.messenger.send("see you later", to: ids.aSeesB)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .waiting)

        b.messenger.start()
        await waitUntil("delivered after reopening") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == ["see you later"])
    }

    @Test func renamedContactIsUpdatedOnReconnect() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        b.messenger.setDisplayName("Blake R.")
        await waitUntil("name updated") { a.messenger.contact(ids.aSeesB)?.displayName == "Blake R." }
        await waitUntil("reconnected") { a.messenger.linkState(for: ids.aSeesB) == .connected }
    }
}

@MainActor
@Suite struct ContactManagementTests {
    @Test func blockedContactDisappearsAndCannotReconnect() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)

        a.messenger.setBlocked(true, for: ids.aSeesB)
        #expect(a.messenger.nearbyPeers.isEmpty)
        #expect(a.messenger.conversationSummaries.isEmpty)
        #expect(a.messenger.linkState(for: ids.aSeesB) == .outOfRange)
        #expect(a.messenger.send("hi", to: ids.aSeesB) == nil)

        // Blake's phone keeps trying; Alex is never prompted and no link forms.
        await pause(200)
        #expect(a.messenger.requests.isEmpty)
        #expect(b.messenger.linkState(for: ids.bSeesA) != .connected)
        b.messenger.send("hello?", to: ids.bSeesA)
        #expect(a.messenger.messages(for: ids.aSeesB).isEmpty)

        a.messenger.setBlocked(false, for: ids.aSeesB)
        await waitUntil("reconnected after unblock") { a.messenger.linkState(for: ids.aSeesB) == .connected }
    }

    @Test func removedContactMustAskAgain() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.send("hi", to: ids.aSeesB)

        a.messenger.removeContact(ids.aSeesB)
        #expect(a.messenger.contacts.isEmpty)
        #expect(a.messenger.messages(for: ids.aSeesB).isEmpty)
        #expect(a.messenger.nearbyPeers.first?.contactID == nil)

        // Blake still has Alex saved and his phone keeps trying to reconnect on its own.
        // That must never show Alex a prompt nobody on Blake's side asked for.
        await pause(250)
        #expect(a.messenger.requests.isEmpty)
        #expect(a.messenger.contacts.isEmpty)
        #expect(b.messenger.linkState(for: ids.bSeesA) != .connected)

        // A person tapping Connect is a real request, even while Blake's phone is retrying.
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        await waitUntil("Blake is asked") { b.messenger.requests.contains { $0.state == .pending } }
        b.messenger.accept(try #require(b.messenger.requests.first { $0.state == .pending }))
        await waitUntil("linked again") {
            a.messenger.contacts.count == 1 && a.messenger.linkState(for: a.messenger.contacts[0].id) == .connected
                && b.messenger.linkState(for: ids.bSeesA) == .connected
        }
        #expect(a.messenger.contacts[0].identityKey == b.messenger.identityKey)
    }

    @Test func removedPersonCanAskAgainWithAPrompt() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.removeContact(ids.aSeesB)
        b.messenger.removeContact(ids.bSeesA)
        b.messenger.connect(to: try #require(b.messenger.nearbyPeers.first))
        let request = try #require(a.messenger.requests.first)
        #expect(request.state == .pending && request.displayName == "Blake")
        a.messenger.accept(request)
        #expect(a.messenger.contacts.count == 1 && b.messenger.contacts.count == 1)
    }

    @Test func verificationAndClearingArePersisted() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.send("hi", to: ids.aSeesB)
        a.messenger.setVerified(true, for: ids.aSeesB)
        #expect(a.persistence.load().contacts.first?.isVerified == true)
        #expect(a.persistence.load().conversations[ids.aSeesB]?.messages.count == 1)
        a.messenger.clearConversation(ids.aSeesB)
        #expect(a.persistence.load().conversations[ids.aSeesB]?.messages.isEmpty == true)
        #expect(a.messenger.contacts.count == 1)
    }

    @Test func stateSurvivesRelaunch() async throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.send("delivered one", to: ids.aSeesB)
        hub.intercept = { data, from, _ in from == b.token ? nil : data }
        a.messenger.send("never confirmed", to: ids.aSeesB)
        let key = a.messenger.identityKey
        hub.intercept = nil
        a.messenger.stop()

        let relaunched = makePhone(hub, "Alex", persistence: a.persistence, identityStore: a.identityStore, start: false)
        #expect(relaunched.messenger.identityKey == key)
        #expect(relaunched.messenger.profile.hasCompletedOnboarding)
        #expect(relaunched.messenger.contacts.map(\.id) == [ids.aSeesB])
        #expect(relaunched.messenger.messages(for: ids.aSeesB).map(\.status) == [.delivered, .waiting])

        relaunched.messenger.start()
        await waitUntil("pending message delivered after relaunch") {
            relaunched.messenger.messages(for: ids.aSeesB).map(\.status) == [.delivered, .delivered]
        }
        #expect(b.messenger.messages(for: ids.bSeesA).map(\.text) == ["delivered one", "never confirmed"])
    }

    @Test func eraseEverythingLeavesNoTrace() throws {
        let hub = LoopbackHub()
        let a = makePhone(hub, "Alex"), b = makePhone(hub, "Blake")
        let ids = try befriend(a, b)
        a.messenger.send("hi", to: ids.aSeesB)
        let oldKey = a.messenger.identityKey

        a.messenger.eraseEverything()
        #expect(a.messenger.contacts.isEmpty && a.messenger.conversations.isEmpty)
        #expect(a.messenger.profile == Profile())
        #expect(a.messenger.availability == .off)
        #expect(a.messenger.identityKey != oldKey)
        let stored = a.persistence.load()
        #expect(stored.contacts.isEmpty && stored.conversations.isEmpty && stored.profile == Profile())
        #expect(b.messenger.linkState(for: ids.bSeesA) == .outOfRange)
    }
}

@MainActor
@Suite struct FilePersistenceTests {
    @Test func roundTripsThroughDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistence(directory: directory)
        #expect(store.load().contacts.isEmpty)

        let identity = Identity()
        let contact = Contact(id: identity.contactID, displayName: "Maya", identityKey: identity.publicKey, isVerified: true)
        let conversation = Conversation(messages: [Message(direction: .outgoing, text: "hi 👋", status: .delivered)], unreadCount: 2)
        store.save(profile: Profile(displayName: "Alex", isVisible: false, hasCompletedOnboarding: true))
        store.save(contacts: [contact])
        let saved = Confirmation()
        store.save(conversation: conversation, for: contact.id) { saved.set($0) }
        store.flush()
        #expect(saved.value == true)

        let loaded = FilePersistence(directory: directory).load()
        #expect(loaded.profile == Profile(displayName: "Alex", isVisible: false, hasCompletedOnboarding: true))
        #expect(loaded.contacts == [contact])
        #expect(loaded.conversations[contact.id] == conversation)

        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)

        store.deleteConversation(for: contact.id)
        store.flush()
        #expect(FilePersistence(directory: directory).load().conversations[contact.id] == Conversation())

        store.eraseAll()
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func burstOfSavesWritesTheLatestStateAndConfirmsAll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePersistence(directory: directory)
        let identity = Identity()
        let contact = Contact(id: identity.contactID, displayName: "Maya", identityKey: identity.publicKey)
        store.save(contacts: [contact])
        var conversation = Conversation()
        let confirmations = (0..<200).map { _ in Confirmation() }
        for confirmation in confirmations {
            conversation.messages.append(Message(direction: .incoming, text: "m", status: .delivered))
            store.save(conversation: conversation, for: contact.id) { confirmation.set($0) }
        }
        store.flush()
        #expect(confirmations.allSatisfy { $0.value == true })
        #expect(FilePersistence(directory: directory).load().conversations[contact.id]?.messages.count == 200)
    }

    @Test func failedSaveIsReported() throws {
        // A file where the storage directory should be makes every write fail.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("x".utf8).write(to: blocker)
        let store = FilePersistence(directory: blocker)
        let saved = Confirmation()
        store.save(conversation: Conversation(), for: ContactID(rawValue: "abc")) { saved.set($0) }
        store.flush()
        #expect(saved.value == false)
    }

    @Test func unreadableFileDoesNotCrashOrGetOverwrittenSilently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("contacts.json"))
        let loaded = FilePersistence(directory: directory).load()
        #expect(loaded.contacts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("contacts.json.unreadable").path))
    }
}

final class Confirmation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
