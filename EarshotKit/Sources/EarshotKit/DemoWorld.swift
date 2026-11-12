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

    public let messenger: Messenger
    private let hub: LoopbackHub
    private var bots: [String: (messenger: Messenger, transport: LoopbackTransport)] = [:]
    private var replyIndex: [String: Int] = [:]

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

    public init(scenario: Scenario = .populated, latency: Duration? = .milliseconds(90)) {
        hub = LoopbackHub(latency: latency)

        let me = Identity()
        let maya = Identity(), jonas = Identity()
        var state = PersistedState()
        let now = Date()

        if scenario != .firstRun {
            state.profile = Profile(displayName: "Alex", isVisible: true, hasCompletedOnboarding: true)
        }
        let attachments = AttachmentStore()
        if scenario == .populated {
            let mayaContact = Contact(id: maya.contactID, displayName: "Maya Okafor", identityKey: maya.publicKey,
                                      addedAt: now.addingTimeInterval(-86_400 * 3), isVerified: true)
            let jonasContact = Contact(id: jonas.contactID, displayName: "Jonas Weber", identityKey: jonas.publicKey,
                                       addedAt: now.addingTimeInterval(-86_400 * 9))
            state.contacts = [mayaContact, jonasContact]
            func message(_ direction: Message.Direction, _ text: String, _ minutesAgo: Double,
                         _ status: DeliveryStatus = .delivered) -> Message {
                Message(direction: direction, text: text, timestamp: now.addingTimeInterval(-minutesAgo * 60), status: status)
            }
            // One photo already in the history, stored like a received one.
            var photoMessage: [Message] = []
            if let picture = try? PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 1600, height: 1200, seed: 1))) {
                let id = UUID()
                let name = AttachmentStore.fileName(for: id)
                if (try? attachments.save(picture.jpeg, as: name)) != nil {
                    photoMessage = [Message(id: id, direction: .incoming, text: "View from carriage 2 😅",
                                            timestamp: now.addingTimeInterval(-32 * 60), status: .delivered,
                                            photo: PhotoAttachment(fileName: name, byteCount: picture.jpeg.count,
                                                                   width: picture.width, height: picture.height))]
                }
            }
            state.conversations[maya.contactID] = Conversation(messages: [
                message(.incoming, "Train's stuck in the tunnel. Zero bars.", 34),
                message(.outgoing, "Same in carriage 4. Are you near the *front*?", 33),
            ] + photoMessage + [
                message(.incoming, "Carriage 2. They say twenty minutes.", 31),
                message(.outgoing, "OK. Meet on the platform by the stairs when we get in?", 30),
                message(.incoming, "Deal. I'll wait by the stairs.", 29),
            ])
            state.conversations[jonas.contactID] = Conversation(messages: [
                message(.incoming, "Main stage is packed, heading to the food trucks.", 60 * 26),
                message(.outgoing, "On my way. Save me a seat.", 60 * 26 - 2),
                message(.outgoing, "Which truck are you at?", 60 * 25, .waiting),
            ])
        }

        messenger = Messenger(transport: hub.makeTransport(token: "me"),
                              persistence: InMemoryPersistence(state),
                              identityStore: InMemoryIdentityStore(me.rawRepresentation),
                              attachments: attachments)

        guard scenario != .empty else { return }
        let meContact = Contact(id: me.contactID, displayName: "Alex", identityKey: me.publicKey)
        addBot("Maya Okafor", identity: maya, knows: scenario == .populated ? [meContact] : [], accepts: true)
        // Priya runs an older Earshot that cannot receive photos, so that state can be seen.
        addBot("Priya Raman", identity: Identity(), knows: [], accepts: true, legacy: true)
        addBot("Tomás", identity: Identity(), knows: [], accepts: false)
        // Jonas is a saved contact who is not around, so he gets no bot.
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
