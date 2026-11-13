import Foundation

/// A self-contained pretend neighbourhood for previews, screenshots and UI tests.
///
/// The "other phones" are real `Messenger` instances talking to yours through an
/// in-memory `LoopbackHub`, so every state you see is produced by the real engine.
/// The shipping app only creates a `DemoWorld` when launched with the `-demo` argument.
@MainActor
public final class DemoWorld {
    public enum Scenario: String, Sendable {
        /// Onboarded, two saved contacts with history, two new people nearby.
        case populated
        /// Fresh install with people nearby.
        case firstRun
        /// Onboarded, nobody around, no conversations.
        case empty
    }

    /// Opt-in relaying states for screenshots and UI tests (`-demoRelay …`). With the default
    /// (nothing set) the demo is exactly as before. Only used with the `populated` scenario.
    public struct RelayDemo: Sendable, Equatable {
        /// Alice's waiting message is sealed and this many friends' phones hold a copy.
        public var sealedHandoffs: Int?
        /// Alice's last message came back Delivered through friends, and his reply arrived the same way.
        public var deliveredViaFriends = false
        /// This phone is carrying a few sealed messages for friends.
        public var carrying = false

        public init(sealedHandoffs: Int? = nil, deliveredViaFriends: Bool = false, carrying: Bool = false) {
            self.sealedHandoffs = sealedHandoffs
            self.deliveredViaFriends = deliveredViaFriends
            self.carrying = carrying
        }
    }

    public let messenger: Messenger
    private let hub: LoopbackHub
    private var bots: [String: (messenger: Messenger, transport: LoopbackTransport)] = [:]
    private var replyIndex: [String: Int] = [:]
    private var jonasWaitingID: UUID?

    private static let replies = [
        "Got it 👍",
        "I'm by the north entrance, next to the coffee cart.",
        "Give me five minutes.",
        "Works for me. See you there.",
        "No signal here either — glad this works.",
    ]

    /// A made-up landscape picture, the same on every launch, used as "the photo you picked"
    /// in demo mode and UI tests (the system photo picker cannot be driven reliably by tests).
    /// What a demo person sends back when asked for a photo.
    static let samplePhoto2: PreparedPhoto? =
        try? PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 1200, height: 1600, seed: 2)))

    public static let samplePhoto: PreparedPhoto? =
        try? PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 1600, height: 1200, seed: 0)))

    public init(scenario: Scenario = .populated, latency: Duration? = .milliseconds(90), relay: RelayDemo = RelayDemo()) {
        hub = LoopbackHub(latency: latency)

        let me = Identity()
        let maya = Identity(), jonas = Identity()
        var state = PersistedState()
        let now = Date()

        if scenario != .firstRun {
            state.profile = Profile(displayName: "Chinmay", isVisible: true, hasCompletedOnboarding: true)
        }
        let attachments = AttachmentStore()
        if scenario == .populated {
            let mayaContact = Contact(id: maya.contactID, displayName: "Jensen Huang", identityKey: maya.publicKey,
                                      addedAt: now.addingTimeInterval(-86_400 * 3), isVerified: true)
            let jonasContact = Contact(id: jonas.contactID, displayName: "Alice Huang", identityKey: jonas.publicKey,
                                       addedAt: now.addingTimeInterval(-86_400 * 9))
            state.contacts = [mayaContact, jonasContact]
            func message(_ direction: Message.Direction, _ text: String, _ minutesAgo: Double,
                         _ status: DeliveryStatus = .delivered) -> Message {
                Message(direction: direction, text: text, timestamp: now.addingTimeInterval(-minutesAgo * 60), status: status)
            }
            // One photo already in Alice's history, stored like a received one.
            var photoMessage: [Message] = []
            if let picture = try? PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 1600, height: 1200, seed: 1))) {
                let id = UUID()
                let name = AttachmentStore.fileName(for: id)
                if (try? attachments.save(picture.jpeg, as: name)) != nil {
                    photoMessage = [Message(id: id, direction: .incoming, text: "The queue for the food trucks 😅",
                                            timestamp: now.addingTimeInterval(-60 * 26 * 60 + 30), status: .delivered,
                                            photo: PhotoAttachment(fileName: name, byteCount: picture.jpeg.count,
                                                                   width: picture.width, height: picture.height))]
                }
            }
            state.conversations[maya.contactID] = Conversation(messages: [
                message(.incoming, "Train's stuck in the tunnel. Zero bars.", 34),
                message(.outgoing, "Same in carriage 4. Are you near the *front*?", 33),
                message(.incoming, "Carriage 2. They say twenty minutes.", 31),
                message(.outgoing, "OK. Meet on the platform by the stairs when we get in?", 30),
                message(.incoming, "Deal. I'll wait by the stairs.", 29),
            ])
            var jonasMessages = [
                message(.incoming, "Main stage is packed, heading to the food trucks.", 60 * 26),
            ] + photoMessage + [
                message(.outgoing, "On my way. Save me a seat.", 60 * 26 - 2),
                message(.outgoing, "Which truck are you at?", 60 * 25, .waiting),
            ]
            if relay.deliveredViaFriends {
                jonasMessages[jonasMessages.count - 1].status = .delivered
                jonasMessages[jonasMessages.count - 1].relayed = true
                var reply = message(.incoming, "The blue one past the stage. Your message came the long way round!", 60 * 25 - 40)
                reply.relayed = true
                jonasMessages.append(reply)
            }
            jonasWaitingID = jonasMessages.last { $0.status == .waiting }?.id
            state.conversations[jonas.contactID] = Conversation(messages: jonasMessages)
        }

        messenger = Messenger(transport: hub.makeTransport(token: "me"),
                              persistence: InMemoryPersistence(state),
                              identityStore: InMemoryIdentityStore(me.rawRepresentation),
                              attachments: attachments)
        if scenario == .populated, relay != RelayDemo() {
            applyRelayDemo(relay, jonas: jonas.contactID, maya: maya.contactID)
        }

        guard scenario != .empty else { return }
        let meContact = Contact(id: me.contactID, displayName: "Chinmay", identityKey: me.publicKey)
        addBot("Jensen Huang", identity: maya, knows: scenario == .populated ? [meContact] : [], accepts: true)
        // Aubrey runs an older Earshot that cannot receive photos, so that state can be seen.
        addBot("Aubrey Graham", identity: Identity(), knows: [], accepts: true, legacy: true)
        addBot("Tomás", identity: Identity(), knows: [], accepts: false)
        // Alice is a saved contact who is not around, so he gets no bot.
    }

    /// Puts the engine's relay state into a demo situation. The keys and envelopes are made up
    /// (no real phone could open them); everything shown about them comes from the real engine.
    private func applyRelayDemo(_ demo: RelayDemo, jonas: ContactID, maya: ContactID) {
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
        func envelope(size: Int) -> Data {
            var bytes = Data([RelayEnvelope.version])
            bytes.append(random(32)) // one-time tag + receipt hash
            withUnsafeBytes(of: RelayEnvelope.expiresHour(at: Date()).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(random(size - bytes.count))
            return bytes
        }
        // As if Chinmay and Alice had confirmed relay keys the last time they met.
        let generation = random(8)
        if demo.sealedHandoffs != nil || demo.deliveredViaFriends {
            messenger.relay.keys.pairs[jonas.rawValue] = PairKeys(send: SendChain(generation: generation, index: 1, key: random(32)))
        }
        if let handoffs = demo.sealedHandoffs, let waiting = jonasWaitingID {
            // Friends' phones that took a copy: Jensen, plus made-up others (never shown by name).
            let carriers = [maya] + (0..<max(0, handoffs - 1)).map { ContactID(rawValue: "demo-friend-\($0)") }
            messenger.relay.keys.outbox.append(RelayOutgoing(
                messageID: waiting, contact: jonas, envelope: envelope(size: 512), receiptSecret: random(16),
                generation: generation, index: 0, carriers: Array(carriers.prefix(handoffs))))
        }
        if demo.carrying {
            for size in [512, 2048, 512] {
                let bytes = envelope(size: size)
                if let parsed = RelayEnvelope(parsing: bytes) {
                    messenger.relay.carried.append(CarriedEnvelope(envelope: parsed, id: RelayCrypto.envelopeID(bytes)))
                }
            }
        }
        messenger.refreshRelayState()
    }

    private func addBot(_ name: String, identity: Identity, knows contacts: [Contact], accepts: Bool, legacy: Bool = false) {
        let transport = hub.makeTransport(token: "bot-" + name)
        var state = PersistedState()
        state.profile = Profile(displayName: name, isVisible: true, hasCompletedOnboarding: true)
        state.contacts = contacts
        var configuration = Messenger.Configuration()
        configuration.legacyProtocolForTesting = legacy
        let bot = Messenger(transport: transport, persistence: InMemoryPersistence(state),
                            identityStore: InMemoryIdentityStore(identity.rawRepresentation),
                            configuration: configuration)
        bot.onEvent = { [weak self, weak bot] event in
            switch event {
            case .requestReceived(let request):
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(accepts ? 1.6 : 4))
                    if accepts { bot?.accept(request) } else { bot?.decline(request) }
                }
            case .messageReceived(let id, let message):
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.8))
                    guard let self, let bot else { return }
                    if message.photo != nil {
                        bot.send("Got the photo, thanks! 📷", to: id)
                        return
                    }
                    // Ask a demo person for a "photo" and they send one back (for trying out receiving).
                    if message.text.localizedCaseInsensitiveContains("photo"), let picture = Self.samplePhoto2 {
                        if bot.sendPhoto(picture, caption: "Here you go", to: id) != nil { return }
                    }
                    let index = self.replyIndex[name, default: 0]
                    self.replyIndex[name] = index + 1
                    bot.send(Self.replies[index % Self.replies.count], to: id)
                }
            case .connected:
                break
            }
        }
        bots[name] = (bot, transport)
        bot.start()
    }

    /// Makes a demo person walk out of range or come back.
    public func setInRange(_ inRange: Bool, name: String) {
        guard let bot = bots[name] else { return }
        hub.setReachable(inRange, bot.transport)
    }

    /// Makes a new demo person send you a connection request.
    public func receiveRequest(from name: String = "Noor Haddad") {
        if bots[name] == nil { addBot(name, identity: Identity(), knows: [], accepts: true) }
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let bot = bots[name]?.messenger else { return }
                if let me = bot.nearbyPeers.first(where: { $0.id.rawValue == "me" }) {
                    bot.connect(to: me)
                    return
                }
            }
        }
    }
}
