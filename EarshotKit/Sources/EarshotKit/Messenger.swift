import Foundation
import Observation

/// The heart of Earshot. Owns identity, contacts, conversations and every link
/// to a nearby phone, and exposes them as observable state for the interface.
///
/// A link goes through four steps:
/// 1. **Consent** – one person sends a request, the other accepts. Saved contacts
///    that recognise each other skip the prompt.
/// 2. **Key exchange** – both phones swap one-time keys and derive an encrypted channel.
/// 3. **Proof of identity** – inside that channel each phone signs the exchange with
///    its long-term key. A saved contact must present the key we stored for them.
/// 4. **Messages** – every message gets a receipt from the other phone.
@MainActor
@Observable
public final class Messenger {
    public struct Configuration: Sendable {
        /// How long to wait for a delivery receipt before marking a message failed.
        public var ackTimeout: Duration = .seconds(10)
        /// How long the key exchange and identity proof may take.
        public var handshakeTimeout: Duration = .seconds(12)
        /// How long the other person has to answer a connection request.
        public var inviteTimeout: TimeInterval = 45
        /// Waits between automatic reconnection attempts to a saved contact.
        public var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)]
        /// When two phones could both start a link, the one with the higher
        /// random number holds back this long so they do not collide.
        public var tieBreakDelay: Duration = .seconds(3)
        /// After those, a contact that is still in range is retried at this slower pace for as long as it stays.
        public var steadyRetryDelay: Duration = .seconds(30)
        public var maxLinks = 6
        /// More unanswered requests than this are dropped without a prompt.
        public var maxPendingRequests = 4
        /// A link may deliver this many messages in a burst, then `incomingRate` per second.
        public var incomingBurst = 60.0
        public var incomingRate = 5.0

        // Photos. See `Messenger+Photos.swift` and `PhotoLimits`.
        /// A photo being sent fails if the other phone confirms no new piece for this long.
        /// (Not a fixed total: a big photo on a slow link may take a minute and still succeed.)
        public var photoStallTimeout: Duration = .seconds(20)
        /// A photo being received is thrown away if no piece arrives for this long.
        public var incomingPhotoIdleTimeout: Duration = .seconds(30)
        /// Photos are refused once stored photos would take more than this.
        public var photoStorageQuota = 300 * 1024 * 1024
        /// A link may deliver this many photo bytes in a burst, then `incomingPhotoByteRate` per second.
        /// Far above what Bluetooth LE can carry; it only stops a flood over faster radios.
        public var incomingPhotoByteBurst = 2.0 * 1024 * 1024
        public var incomingPhotoByteRate = 1.0 * 1024 * 1024
        /// Tests only: behave like Earshot before photos existed. Announces no features and
        /// closes the link on any photo payload, exactly as an older version's decoder would.
        var legacyProtocolForTesting = false

        public init() {}
    }

    public enum Event: Sendable {
        case requestReceived(ConnectionRequest)
        case connected(ContactID)
        case messageReceived(ContactID, Message)
    }

    // MARK: Observable state

    public private(set) var profile: Profile
    public private(set) var availability: Availability = .off
    public private(set) var contacts: [Contact]
    public internal(set) var conversations: [ContactID: Conversation]
    /// Devices detected nearby, including saved contacts (those have `contactID` set).
    public private(set) var nearbyPeers: [NearbyPeer] = []
    public private(set) var requests: [ConnectionRequest] = []
    public private(set) var linkStates: [ContactID: LinkState] = [:]
    /// Contacts that are connected right now over a link whose other end announced it can
    /// receive photos. Only these can be sent a new photo.
    public internal(set) var photoCapableContacts: Set<ContactID> = []
    /// How far each photo transfer has got, from 0 to 1, by message ID (sending and receiving).
    public internal(set) var photoProgress: [UUID: Double] = [:]
    /// Photos arriving right now, per contact, for drawing placeholders. They become
    /// ordinary messages once fully received and checked.
    public internal(set) var incomingPhotos: [ContactID: [IncomingPhoto]] = [:]
    /// Why a photo was not delivered, when there is something more specific to say. Not saved.
    public internal(set) var photoFailures: [UUID: PhotoFailure] = [:]

    // MARK: Internals
    // Internal rather than private where `Messenger+Photos.swift` needs them.

    struct Link {
        enum Role { case inviter, invitee }
        enum Phase {
            case connecting
            case awaitingHello(Handshake)
            case awaitingAuth(localEphemeral: Data, remoteEphemeral: Data)
            case established(ContactID)
        }

        let id = UUID()
        let token: PeerToken
        var role: Role
        /// The saved contact we believe this is. The identity proof must match it.
        var expected: ContactID?
        /// True when a person on this phone tapped Connect or Accept for this link.
        var userInitiated: Bool
        var phase: Phase = .connecting
        var channel: SecureChannel?
        /// Whether this phone has revealed its identity on this link yet.
        var authSent = false
        /// Allowance for incoming messages; refills over time. Stops a flood from one link.
        var incomingBudget = 0.0
        var budgetUpdated = ContinuousClock.now
        /// What the other phone announced in its identity proof on this link (`Feature`).
        var peerFeatures: Set<String> = []
        /// Allowance for incoming photo bytes, like `incomingBudget`.
        var photoByteBudget = 0.0
        var photoBudgetUpdated = ContinuousClock.now

        var contactID: ContactID? {
            if case .established(let id) = phase { return id }
            return nil
        }
    }

    private struct Discovered {
        let token: PeerToken
        var name: String
        var nonce: Data
        var tag: Data
        var contactID: ContactID?
        var isBlocked = false
        var foundAt = ContinuousClock.now
    }

    enum LinkFailure: Error {
        case protocolViolation
        case verificationFailed
        case incompatibleVersion
        case refused
        case remoteLeft
        case timedOut
    }

    @ObservationIgnored public var onEvent: ((Event) -> Void)?
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored let persistence: Persistence
    @ObservationIgnored let attachments: AttachmentStore
    @ObservationIgnored private let identityStore: IdentityStore
    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored private var identity: Identity
    /// False when the Keychain could not be read; the identity is then temporary and retried on `start()`.
    @ObservationIgnored private var identityIsStored: Bool
    /// Bumped whenever everything is torn down, so timers from before then do nothing.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var inviteSerials: [PeerToken: Int] = [:]
    @ObservationIgnored var links: [PeerToken: Link] = [:]
    @ObservationIgnored private var discovered: [PeerToken: Discovered] = [:]
    @ObservationIgnored private var refusedTokens: Set<PeerToken> = []
    @ObservationIgnored private var reconnectAttempts: [ContactID: Int] = [:]
    @ObservationIgnored var knownMessageIDs: [ContactID: Set<UUID>] = [:]
    @ObservationIgnored private var localNonce = Data()
    @ObservationIgnored private var localTag = Data()
    @ObservationIgnored var activeConversation: ContactID?
    /// Photos this phone is sending, by message ID. At most one per link at a time.
    @ObservationIgnored var outgoingTransfers: [UUID: OutgoingTransfer] = [:]
    /// Photos this phone is receiving, by message ID.
    @ObservationIgnored var incomingTransfers: [UUID: IncomingTransfer] = [:]

    /// - Parameter attachments: where photo files are kept. Defaults to memory (tests, demo mode).
    public init(transport: Transport, persistence: Persistence, identityStore: IdentityStore,
                attachments: AttachmentStore = AttachmentStore(),
                configuration: Configuration = Configuration()) {
        self.transport = transport
        self.persistence = persistence
        self.attachments = attachments
        self.identityStore = identityStore
        self.configuration = configuration

        let loaded = Self.loadIdentity(from: identityStore)
        identity = loaded.identity
        identityIsStored = loaded.stored

        let state = persistence.load()
        profile = state.profile
        contacts = state.contacts
        conversations = state.conversations
        for (id, conversation) in conversations {
            knownMessageIDs[id] = Set(conversation.messages.map(\.id))
            // Anything still "sending" when the app last closed never got a receipt.
            for index in conversation.messages.indices where conversation.messages[index].status == .sending {
                conversations[id]?.messages[index].status = .waiting
            }
        }
        // Photo files that no saved message points to are leftovers: a photo half-received
        // when the app was stopped, or one whose message was deleted just before a crash.
        let referenced = conversations.values.flatMap(\.messages).compactMap(\.photo?.fileName)
        attachments.removeAll(except: Set(referenced))
        transport.eventHandler = { [weak self] event in self?.handle(event) }
    }

    /// Loads the stored identity, or creates one on first launch. If the store cannot be
    /// read or written right now, returns a throwaway identity and `stored == false` —
    /// the real key is never overwritten because of a temporary failure.
    private static func loadIdentity(from store: IdentityStore) -> (identity: Identity, stored: Bool) {
        do {
            if let raw = try store.load() { return (try Identity(rawRepresentation: raw), true) }
            let fresh = Identity()
            try store.save(fresh.rawRepresentation)
            return (fresh, true)
        } catch {
            return (Identity(), false)
        }
    }

    // MARK: Reading state

    public var identityKey: Data { identity.publicKey }

    /// This session's random number, exposed for tests only.
    var currentNonceForTesting: Data? { availability == .on ? localNonce : nil }

    public func contact(_ id: ContactID) -> Contact? { contacts.first { $0.id == id } }

    public func messages(for id: ContactID) -> [Message] { conversations[id]?.messages ?? [] }

    public func linkState(for id: ContactID) -> LinkState { linkStates[id] ?? .outOfRange }

    /// Conversations with non-blocked contacts, most recent first.
    public var conversationSummaries: [ConversationSummary] {
        contacts.filter { !$0.isBlocked }.map { contact in
            let conversation = conversations[contact.id]
            return ConversationSummary(contact: contact, lastMessage: conversation?.messages.last,
                                       unreadCount: conversation?.unreadCount ?? 0,
                                       link: linkState(for: contact.id))
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The number both people compare in person to confirm the link is private.
    public func safetyCode(for id: ContactID) -> String? {
        contact(id).map { SafetyCode.make(identity.publicKey, $0.identityKey) }
    }

    // MARK: Profile

    public func completeOnboarding(displayName: String) {
        profile.displayName = Limits.sanitizedName(displayName)
        profile.hasCompletedOnboarding = true
        persistence.save(profile: profile)
    }

    public func setDisplayName(_ name: String) {
        let clean = Limits.sanitizedName(name)
        guard !clean.isEmpty, clean != profile.displayName else { return }
        profile.displayName = clean
        persistence.save(profile: profile)
        restartIfRunning()
    }

    public func setVisible(_ visible: Bool) {
        guard visible != profile.isVisible else { return }
        profile.isVisible = visible
        persistence.save(profile: profile)
        restartIfRunning()
    }

    // MARK: Going on and off the air

    /// Starts looking for nearby phones. Call once the person has finished onboarding and
    /// on every later launch. The first call makes iOS ask for Bluetooth access.
    /// On a real iPhone this keeps working while the app is in the background.
    public func start() {
        guard availability != .on, !profile.displayName.isEmpty else { return }
        if availability != .off { transport.stop() }
        if !identityIsStored {
            let loaded = Self.loadIdentity(from: identityStore)
            guard loaded.stored else {
                availability = .unavailable(.failedToStart("Earshot could not read this phone's identity key. Unlock the phone and reopen Earshot."))
                return
            }
            identity = loaded.identity
            identityIsStored = true
        }
        localNonce = DiscoveryTag.makeNonce()
        localTag = DiscoveryTag.make(identityKey: identity.publicKey, nonce: localNonce)
        availability = .on
        transport.start(LocalAdvertisement(displayName: profile.displayName, nonce: localNonce,
                                           tag: localTag, isVisible: profile.isVisible))
    }

    /// Closes every link and stops discovery. Not needed when the app merely goes to the
    /// background; use it when Earshot should be off the air.
    public func stop() {
        guard availability != .off else { return }
        for (token, link) in links where link.contactID != nil {
            try? send(.bye, to: token)
        }
        transport.stop()
        tearDown()
        availability = .off
        refresh()
        persistence.flush()
    }

    /// Forgets every link, nearby device and request, and cancels all running timers.
    private func tearDown() {
        epoch += 1
        let open = links.values.compactMap(\.contactID)
        links.removeAll()
        discovered.removeAll()
        refusedTokens.removeAll()
        reconnectAttempts.removeAll()
        requests.removeAll()
        endAllPhotoTransfers()
        open.forEach(parkUnconfirmedMessages)
    }

    private func restartIfRunning() {
        guard availability == .on else { return }
        stop()
        start()
    }

    // MARK: Connection requests

    /// Asks a nearby person to start a conversation. They must accept on their phone.
    public func connect(to peer: NearbyPeer) {
        // If that person has already asked us, tapping Connect is the same as accepting.
        if let incoming = requests.first(where: { $0.id == peer.id && $0.direction == .incoming && $0.state == .pending }) {
            accept(incoming)
            return
        }
        guard availability == .on, links[peer.id] == nil, let found = discovered[peer.id], !found.isBlocked else { return }
        refusedTokens.remove(peer.id)
        if found.contactID == nil {
            requests.removeAll { $0.id == peer.id }
            requests.append(ConnectionRequest(id: peer.id, direction: .outgoing, displayName: found.name, state: .waiting))
        }
        invite(found, userInitiated: true)
        refresh()
    }

    public func accept(_ request: ConnectionRequest) {
        guard let index = requests.firstIndex(where: { $0.id == request.id }),
              requests[index].direction == .incoming, requests[index].state == .pending else { return }
        requests[index].state = .connecting
        let link = Link(token: request.id, role: .invitee, expected: nil, userInitiated: true)
        links[request.id] = link
        transport.respondToInvitation(from: request.id, accept: true)
        watchHandshake(link)
        refresh()
    }

    public func decline(_ request: ConnectionRequest) {
        guard let index = requests.firstIndex(where: { $0.id == request.id }),
              requests[index].direction == .incoming, requests[index].state == .pending else { return }
        requests.remove(at: index)
        refusedTokens.insert(request.id)
        transport.respondToInvitation(from: request.id, accept: false)
    }

    /// Removes a finished, failed or outgoing request from the list.
    /// Cancelling an outgoing request that is still waiting also drops the attempt.
    public func dismiss(_ request: ConnectionRequest) {
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else { return }
        let current = requests[index]
        if current.direction == .incoming, current.state == .pending {
            decline(current)
            return
        }
        requests.remove(at: index)
        if let link = links[current.id], link.contactID == nil {
            links[current.id] = nil
            transport.disconnect(current.id)
        }
        refresh()
    }

    // MARK: Messages

    /// Queues a message. It is sent right away when the contact is connected,
    /// otherwise as soon as they are back in range while the app is open.
    @discardableResult
    public func send(_ text: String, to id: ContactID) -> Message? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Limits.maxMessageLength,
              let contact = contact(id), !contact.isBlocked else { return nil }
        let message = Message(direction: .outgoing, text: trimmed, status: .waiting)
        conversations[id, default: Conversation()].messages.append(message)
        knownMessageIDs[id, default: []].insert(message.id)
        trimHistory(id)
        transmit(message.id, to: id)
        persist(id)
        // In range but not linked (for example after several failed attempts): try again now.
        if link(to: id) == nil { autoConnect(id) }
        return conversations[id]?.messages.first { $0.id == message.id }
    }

    /// Tries a failed message again.
    public func retry(_ messageID: UUID, in id: ContactID) {
        guard let message = messages(for: id).first(where: { $0.id == messageID }),
              message.direction == .outgoing, message.status == .failed else { return }
        setStatus(.waiting, of: messageID, in: id)
        transmit(messageID, to: id)
        persist(id)
    }

    public func deleteMessage(_ messageID: UUID, in id: ContactID) {
        let removed = conversations[id]?.messages.filter { $0.id == messageID } ?? []
        conversations[id]?.messages.removeAll { $0.id == messageID }
        forgetPhotos(of: removed)
        persist(id)
    }

    /// Tells the engine which conversation is on screen so new messages there are not counted as unread.
    public func setActiveConversation(_ id: ContactID?) {
        activeConversation = id
        if let id, let unread = conversations[id]?.unreadCount, unread > 0 {
            conversations[id]?.unreadCount = 0
            persist(id)
        }
    }

    // MARK: Contacts

    public func clearConversation(_ id: ContactID) {
        guard let old = conversations[id] else { return }
        conversations[id] = Conversation()
        forgetPhotos(of: old.messages)
        persist(id)
    }

    /// Forgets a person and their messages. They would have to send a new request to reach you.
    public func removeContact(_ id: ContactID) {
        closeLinks(to: id)
        contacts.removeAll { $0.id == id }
        forgetPhotos(of: conversations[id]?.messages ?? [])
        conversations[id] = nil
        knownMessageIDs[id] = nil
        persistence.save(contacts: contacts)
        persistence.deleteConversation(for: id)
        recogniseDiscovered()
        refresh()
    }

    /// A blocked contact cannot connect or send requests, and does not see a refusal.
    public func setBlocked(_ blocked: Bool, for id: ContactID) {
        guard let index = contacts.firstIndex(where: { $0.id == id }), contacts[index].isBlocked != blocked else { return }
        contacts[index].isBlocked = blocked
        persistence.save(contacts: contacts)
        if blocked { closeLinks(to: id) }
        recogniseDiscovered()
        refresh()
        if !blocked { autoConnect(id) }
    }

    public func setVerified(_ verified: Bool, for id: ContactID) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].isVerified = verified
        persistence.save(contacts: contacts)
    }

    /// Deletes all messages, contacts, the profile and this phone's identity key.
    public func eraseEverything() {
        stop()
        identityStore.delete()
        persistence.eraseAll()
        attachments.deleteAll()
        identity = Identity()
        identityIsStored = (try? identityStore.save(identity.rawRepresentation)) != nil
        profile = Profile()
        contacts = []
        conversations = [:]
        knownMessageIDs = [:]
        activeConversation = nil
    }

    // MARK: Transport events

    private func handle(_ event: TransportEvent) {
        switch event {
        case .found(let token, let advertisement): peerFound(token, advertisement)
        case .lost(let token): discovered[token] = nil
        case .invited(let token, let context): invitationReceived(from: token, context: context)
        case .connected(let token): transportConnected(token)
        case .disconnected(let token):
            if let link = links.removeValue(forKey: token) { linkEnded(link, because: nil) }
        case .received(let data, let token): frameReceived(data, from: token)
        case .unavailable(let problem):
            guard availability == .on else { return }
            // With Bluetooth off or a permission missing no link can exist, but the transport
            // keeps watching for that to change. Any other failure shuts it down.
            if !problem.recoversByItself { transport.stop() }
            tearDown()
            availability = .unavailable(problem)
        case .ready:
            if case .unavailable(let problem) = availability, problem.recoversByItself { start() }
        }
        refresh()
    }

    private func recognise(nonce: Data, tag: Data) -> Contact? {
        guard nonce.count == DiscoveryTag.nonceLength, tag.count == DiscoveryTag.tagLength else { return nil }
        return contacts.first { DiscoveryTag.make(identityKey: $0.identityKey, nonce: nonce) == tag }
    }

    private func recogniseDiscovered() {
        for token in discovered.keys {
            guard let found = discovered[token] else { continue }
            let contact = recognise(nonce: found.nonce, tag: found.tag)
            discovered[token]?.contactID = contact?.id
            discovered[token]?.isBlocked = contact?.isBlocked ?? false
        }
    }

    private func peerFound(_ token: PeerToken, _ advertisement: LocalAdvertisement) {
        guard availability == .on else { return }
        let name = Limits.sanitizedName(advertisement.displayName)
        guard !name.isEmpty else { return }
        var found = Discovered(token: token, name: name, nonce: advertisement.nonce, tag: advertisement.tag)
        if let contact = recognise(nonce: advertisement.nonce, tag: advertisement.tag) {
            found.contactID = contact.id
            found.isBlocked = contact.isBlocked
        }
        discovered[token] = found
        guard let id = found.contactID, !found.isBlocked else { return }
        reconnectAttempts[id] = 0
        if localNonce.lexicographicallyPrecedes(found.nonce) {
            autoConnect(id)
        } else {
            after(configuration.tieBreakDelay) { $0.autoConnect(id) }
        }
    }

    private func link(to id: ContactID) -> Link? {
        links.values.first { $0.contactID == id || $0.expected == id }
    }

    /// Opens a link to a saved contact that is in range, without asking anyone:
    /// both people already agreed to talk when they first connected.
    private func autoConnect(_ id: ContactID) {
        guard availability == .on, link(to: id) == nil, links.count < configuration.maxLinks,
              let contact = contact(id), !contact.isBlocked,
              // A contact who reopened Earshot can briefly appear twice; the newest sighting is the live one.
              let found = discovered.values.filter({ $0.contactID == id && !refusedTokens.contains($0.token) })
                  .max(by: { $0.foundAt < $1.foundAt })
        else { return }
        invite(found, userInitiated: false)
        refresh()
    }

    private func invite(_ found: Discovered, userInitiated: Bool) {
        let link = Link(token: found.token, role: .inviter, expected: found.contactID, userInitiated: userInitiated)
        links[found.token] = link
        var context = InviteContext(nonce: localNonce)
        if let contact = found.contactID.flatMap(contact) {
            // Reconnecting: no name, just a tag only this contact can check.
            context.tag = PairTag.make(identity.publicKey, contact.identityKey,
                                       inviterNonce: localNonce, inviteeNonce: found.nonce)
        } else {
            context.name = profile.displayName
        }
        transport.invite(found.token, context: context.encoded(), timeout: configuration.inviteTimeout)
        // The radio layer should report an unanswered invitation itself; this is the backstop.
        let id = link.id, token = found.token
        after(.seconds(configuration.inviteTimeout + 5)) { messenger in
            guard let current = messenger.links[token], current.id == id, case .connecting = current.phase else { return }
            messenger.drop(token, because: .timedOut)
            messenger.refresh()
        }
    }

    private func invitationReceived(from token: PeerToken, context: Data) {
        inviteSerials[token, default: 0] += 1
        let serial = inviteSerials[token]
        func decline() { transport.respondToInvitation(from: token, accept: false) }
        func acceptAsInvitee(expected: ContactID?, userInitiated: Bool) {
            let link = Link(token: token, role: .invitee, expected: expected, userInitiated: userInitiated)
            links[token] = link
            transport.respondToInvitation(from: token, accept: true)
            watchHandshake(link)
        }

        guard availability == .on, let invite = InviteContext.decode(context), invite.v == 1,
              invite.nonce.count == DiscoveryTag.nonceLength, !refusedTokens.contains(token) else { return decline() }

        var known: Contact?
        var name = ""
        if let tag = invite.tag {
            // An automatic reconnection. It never becomes a prompt: either the tag proves
            // it comes from a saved, unblocked contact, or it is dropped without a trace.
            known = contacts.first {
                PairTag.make(identity.publicKey, $0.identityKey, inviterNonce: invite.nonce, inviteeNonce: localNonce) == tag
            }
            guard let known, !known.isBlocked else { return decline() }
        } else {
            name = Limits.sanitizedName(invite.name ?? "")
            guard !name.isEmpty else { return decline() }
        }

        if let existing = links[token] {
            guard case .connecting = existing.phase, existing.role == .inviter else { return decline() }
            if known == nil, !existing.userInitiated {
                // Our phone was reconnecting on its own while a person on theirs sent a
                // request. The person's request matters more: withdraw ours and show theirs.
                links[token] = nil
                transport.disconnect(token)
            } else if localNonce.lexicographicallyPrecedes(invite.nonce) {
                // Both asked at the same moment and ours wins. Theirs is answered late so
                // that answering it cannot knock ours over.
                after(.seconds(5)) { messenger in
                    guard messenger.inviteSerials[token] == serial else { return }
                    messenger.transport.respondToInvitation(from: token, accept: false)
                }
                return
            } else {
                return acceptAsInvitee(expected: known?.id ?? existing.expected, userInitiated: existing.userInitiated)
            }
        }

        if let known {
            // One attempt per contact at a time. An already working link is replaced
            // only once the new one has proven itself (see `establish`).
            let pending = links.values.contains { $0.expected == known.id && $0.contactID == nil }
            guard !pending, links.count < configuration.maxLinks else { return decline() }
            acceptAsInvitee(expected: known.id, userInitiated: false)
        } else {
            let waiting = requests.filter { $0.direction == .incoming && $0.state == .pending && $0.id != token }.count
            guard waiting < configuration.maxPendingRequests else { return decline() }
            requests.removeAll { $0.id == token }
            let request = ConnectionRequest(id: token, direction: .incoming, displayName: name, state: .pending)
            requests.append(request)
            onEvent?(.requestReceived(request))
            // The other phone gives up after `inviteTimeout`; stop offering Accept shortly before.
            after(.seconds(max(configuration.inviteTimeout - 3, 1))) { messenger in
                guard messenger.inviteSerials[token] == serial,
                      let index = messenger.requests.firstIndex(where: { $0.id == token && $0.state == .pending }) else { return }
                messenger.requests.remove(at: index)
                messenger.transport.respondToInvitation(from: token, accept: false)
            }
        }
    }

    private func transportConnected(_ token: PeerToken) {
        guard var link = links[token], case .connecting = link.phase else {
            if links[token] == nil { transport.disconnect(token) }
            return
        }
        let handshake = Handshake()
        link.phase = .awaitingHello(handshake)
        links[token] = link
        updateRequest(token) { if $0.state == .waiting { $0.state = .connecting } }
        do {
            try transport.send(Frame.hello(version: Handshake.version, ephemeralKey: handshake.publicKey).encoded(), to: token)
        } catch {
            drop(token, because: .protocolViolation)
            return
        }
        if link.role == .inviter { watchHandshake(link) }
    }

    /// Gives up on a link that has not finished setting up in time.
    private func watchHandshake(_ link: Link) {
        let id = link.id, token = link.token
        after(configuration.handshakeTimeout) { messenger in
            guard let current = messenger.links[token], current.id == id, current.contactID == nil else { return }
            messenger.drop(token, because: .timedOut)
            messenger.refresh()
        }
    }

    private func frameReceived(_ data: Data, from token: PeerToken) {
        // Data can outrun the "connected" notification. Data arriving proves the link is up.
        if let pending = links[token], case .connecting = pending.phase { transportConnected(token) }
        guard var link = links[token] else { return }
        do {
            switch try Frame(decoding: data) {
            case .hello(let version, let remoteEphemeral):
                guard case .awaitingHello(let handshake) = link.phase else { throw LinkFailure.protocolViolation }
                guard version == Handshake.version else { throw LinkFailure.incompatibleVersion }
                link.channel = try handshake.channel(remoteEphemeral: remoteEphemeral)
                link.phase = .awaitingAuth(localEphemeral: handshake.publicKey, remoteEphemeral: remoteEphemeral)
                links[token] = link
                if let expected = link.expected, let contact = contact(expected) {
                    // Reconnecting to a saved contact: stay anonymous until the other
                    // phone shows it really knows us. See `Knock`.
                    try send(.knock(Knock.make(ownIdentityKey: identity.publicKey, peerIdentityKey: contact.identityKey,
                                               signerEphemeral: handshake.publicKey, peerEphemeral: remoteEphemeral)), to: token)
                } else {
                    // A new person, and someone on this phone tapped Connect or Accept.
                    try sendAuth(to: token)
                }

            case .sealed(let box):
                guard var channel = link.channel else { throw LinkFailure.protocolViolation }
                let plaintext = try channel.open(box)
                link.channel = channel
                links[token] = link
                try handle(try Payload.decode(plaintext), from: token)
            }
        } catch let failure as LinkFailure {
            drop(token, because: failure)
        } catch {
            drop(token, because: .protocolViolation)
        }
    }

    private func handle(_ payload: Payload, from token: PeerToken) throws {
        guard let link = links[token] else { return }
        switch (payload, link.phase) {
        case (.knock(let knock), .awaitingAuth(let localEphemeral, let remoteEphemeral)):
            // Only matters if we are still holding back our identity.
            guard !link.authSent, let expected = link.expected, let contact = contact(expected) else { return }
            let valid = Knock.make(ownIdentityKey: identity.publicKey, peerIdentityKey: contact.identityKey,
                                   signerEphemeral: remoteEphemeral, peerEphemeral: localEphemeral)
            guard knock == valid else { throw LinkFailure.verificationFailed }
            try sendAuth(to: token)

        case (.auth(let auth), .awaitingAuth(let localEphemeral, let remoteEphemeral)):
            let transcript = Handshake.transcript(signerEphemeral: remoteEphemeral, peerEphemeral: localEphemeral)
            guard auth.identityKey.count == 32, auth.identityKey != identity.publicKey,
                  Identity.verify(signature: auth.signature, of: transcript, identityKey: auth.identityKey)
            else { throw LinkFailure.verificationFailed }
            // Trust only what this link announced: a contact may have changed Earshot versions.
            links[token]?.peerFeatures = Self.acceptedFeatures(auth.features)
            try establish(token, identityKey: auth.identityKey, name: auth.name)

        case (.text(let text), .established(let id)):
            guard text.text.count <= Limits.maxMessageLength, !text.text.isEmpty else { throw LinkFailure.protocolViolation }
            try chargeIncomingMessage(on: token)
            if knownMessageIDs[id]?.contains(text.id) == true {
                // A repeat: the first receipt may have been lost, so confirm again.
                try send(.ack(text.id), to: token)
                return
            }
            let message = Message(id: text.id, direction: .incoming, text: text.text, status: .delivered)
            storeIncoming(message, from: id, token: token, linkID: link.id)

        case (.ack(let messageID), .established(let id)):
            if let message = messages(for: id).first(where: { $0.id == messageID }),
               message.direction == .outgoing, message.status != .delivered {
                setStatus(.delivered, of: messageID, in: id)
                persist(id)
            }
            photoDelivered(messageID, on: token)

        case (.photoStart, .established), (.photoPiece, .established), (.photoProgress, .established),
             (.photoCancel, .established), (.photoRefuse, .established):
            // An older Earshot cannot decode these at all and closes the link; the test switch copies that.
            if configuration.legacyProtocolForTesting { throw LinkFailure.protocolViolation }
            try handlePhoto(payload, from: token)

        case (.bye, .established):
            throw LinkFailure.remoteLeft

        default:
            throw LinkFailure.protocolViolation
        }
    }

    /// Stores a received message and sends the receipt once it is safely saved:
    /// "Delivered" on the other phone means stored on this one.
    func storeIncoming(_ message: Message, from id: ContactID, token: PeerToken, linkID: UUID) {
        conversations[id, default: Conversation()].messages.append(message)
        knownMessageIDs[id, default: []].insert(message.id)
        trimHistory(id)
        if activeConversation != id { conversations[id]?.unreadCount += 1 }
        onEvent?(.messageReceived(id, message))

        guard let conversation = conversations[id] else { return }
        let messageID = message.id
        persistence.save(conversation: conversation, for: id) { [weak self] stored in
            guard stored else { return }
            let confirm: @MainActor @Sendable () -> Void = {
                guard let self, self.links[token]?.id == linkID else { return }
                try? self.send(.ack(messageID), to: token)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated(confirm)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated(confirm) }
            }
        }
    }

    private func establish(_ token: PeerToken, identityKey: Data, name: String) throws {
        guard var link = links[token] else { return }
        let id = ContactID(identityKey: identityKey)
        if let expected = link.expected, expected != id { throw LinkFailure.verificationFailed }
        let cleanName = Limits.sanitizedName(name)
        guard !cleanName.isEmpty else { throw LinkFailure.protocolViolation }

        if let index = contacts.firstIndex(where: { $0.id == id }) {
            guard !contacts[index].isBlocked else { throw LinkFailure.refused }
            if contacts[index].displayName != cleanName {
                contacts[index].displayName = cleanName
                persistence.save(contacts: contacts)
            }
        } else {
            // A new person only becomes a contact when someone on this phone asked for it.
            guard link.userInitiated else { throw LinkFailure.verificationFailed }
            contacts.append(Contact(id: id, displayName: cleanName, identityKey: identityKey))
            conversations[id] = Conversation()
            persistence.save(contacts: contacts)
            persist(id)
        }

        // Keep one link per contact; the newest wins. That includes attempts still in progress.
        for (other, stale) in links where other != token && (stale.contactID == id || stale.expected == id) {
            links[other] = nil
            transport.disconnect(other)
            endPhotoTransfers(on: other)
        }
        // They have proven who they are. If we were holding back, prove ourselves now.
        if !link.authSent {
            try sendAuth(to: token)
            guard let updated = links[token] else { return }
            link = updated
        }
        link.phase = .established(id)
        link.incomingBudget = configuration.incomingBurst
        link.budgetUpdated = .now
        link.photoByteBudget = configuration.incomingPhotoByteBurst
        link.photoBudgetUpdated = .now
        links[token] = link
        discovered[token]?.contactID = id
        reconnectAttempts[id] = 0
        updateRequest(token) { $0.state = .connected(id) }
        onEvent?(.connected(id))

        for message in messages(for: id) where message.direction == .outgoing && (message.status == .waiting || message.status == .sending) {
            transmit(message.id, to: id)
        }
        persist(id)
    }

    // MARK: Link teardown and recovery

    func drop(_ token: PeerToken, because failure: LinkFailure) {
        guard let link = links.removeValue(forKey: token) else { return }
        transport.disconnect(token)
        linkEnded(link, because: failure)
    }

    private func closeLinks(to id: ContactID) {
        for (token, link) in links where link.contactID == id || link.expected == id {
            links[token] = nil
            transport.disconnect(token)
            endPhotoTransfers(on: token)
        }
        parkUnconfirmedMessages(id)
    }

    private func linkEnded(_ link: Link, because failure: LinkFailure?) {
        endPhotoTransfers(on: link.token)
        if let id = link.contactID {
            parkUnconfirmedMessages(id)
            scheduleReconnect(id)
            return
        }
        updateRequest(link.token) { request in
            guard request.state == .waiting || request.state == .connecting else { return }
            let unanswered = request.state == .waiting && (failure == nil || failure == .timedOut)
            switch failure {
            case .verificationFailed, .refused: request.state = .failed(.verificationFailed)
            case .incompatibleVersion: request.state = .failed(.incompatibleVersion)
            default: request.state = .failed(unanswered ? .noAnswer : .connectionLost)
            }
        }
        if !link.userInitiated, let expected = link.expected, failure != .verificationFailed, failure != .refused {
            scheduleReconnect(expected)
        }
    }

    private func scheduleReconnect(_ id: ContactID) {
        guard availability == .on else { return }
        let attempt = reconnectAttempts[id, default: 0]
        reconnectAttempts[id] = attempt + 1
        // A few quick attempts, then a slow steady pace for as long as the contact stays in range.
        var delay = attempt < configuration.reconnectDelays.count
            ? configuration.reconnectDelays[attempt] : configuration.steadyRetryDelay
        if let found = discovered.values.first(where: { $0.contactID == id }),
           !localNonce.lexicographicallyPrecedes(found.nonce) {
            delay += configuration.tieBreakDelay
        }
        after(delay) { messenger in
            messenger.autoConnect(id)
            // If nothing could be started (for example every link slot is busy), keep the retry alive.
            let inRange = messenger.discovered.values.contains {
                $0.contactID == id && !$0.isBlocked && !messenger.refusedTokens.contains($0.token)
            }
            if messenger.link(to: id) == nil, inRange { messenger.scheduleReconnect(id) }
        }
    }

    /// Messages that were on their way when a link dropped go back to "waiting"
    /// and are sent again on reconnect. The receiver ignores any it already has.
    private func parkUnconfirmedMessages(_ id: ContactID) {
        guard let messages = conversations[id]?.messages else { return }
        var changed = false
        for index in messages.indices where messages[index].direction == .outgoing && messages[index].status == .sending {
            conversations[id]?.messages[index].status = .waiting
            changed = true
        }
        if changed { persist(id) }
    }

    // MARK: Sending

    func send(_ payload: Payload, to token: PeerToken) throws {
        guard var link = links[token], var channel = link.channel else { throw TransportError.notConnected }
        let sealed = try channel.seal(try payload.encoded())
        link.channel = channel
        links[token] = link
        try transport.send(Frame.sealed(sealed).encoded(), to: token)
    }

    /// Reveals this phone's identity to the other side and proves it with a signature.
    private func sendAuth(to token: PeerToken) throws {
        guard var link = links[token], case .awaitingAuth(let localEphemeral, let remoteEphemeral) = link.phase else {
            throw LinkFailure.protocolViolation
        }
        let transcript = Handshake.transcript(signerEphemeral: localEphemeral, peerEphemeral: remoteEphemeral)
        link.authSent = true
        links[token] = link
        try send(.auth(.init(identityKey: identity.publicKey, name: profile.displayName,
                             signature: try identity.sign(transcript),
                             features: configuration.legacyProtocolForTesting ? nil : Feature.all)), to: token)
    }

    func transmit(_ messageID: UUID, to id: ContactID) {
        guard let message = messages(for: id).first(where: { $0.id == messageID }),
              let link = links.values.first(where: { $0.contactID == id }) else { return }
        if message.photo != nil { return transmitPhoto(message, to: id, over: link) }
        // Mark it first: on a fast link the receipt can arrive before `send` returns.
        setStatus(.sending, of: messageID, in: id)
        do {
            try send(.text(.init(id: message.id, text: message.text)), to: link.token)
            let linkID = link.id
            after(configuration.ackTimeout) { messenger in
                guard messenger.links[link.token]?.id == linkID,
                      messenger.messages(for: id).first(where: { $0.id == messageID })?.status == .sending else { return }
                messenger.setStatus(.failed, of: messageID, in: id)
                messenger.persist(id)
            }
        } catch {
            // The link is gone but we have not been told yet. Park the message and let
            // the normal reconnection path send it again.
            setStatus(.waiting, of: messageID, in: id)
            drop(link.token, because: .protocolViolation)
        }
    }

    /// Enforces the per-link allowance for incoming messages.
    func chargeIncomingMessage(on token: PeerToken) throws {
        guard var link = links[token] else { return }
        let now = ContinuousClock.now
        let elapsed = Double((now - link.budgetUpdated).components.seconds)
            + Double((now - link.budgetUpdated).components.attoseconds) / 1e18
        link.incomingBudget = min(configuration.incomingBurst, link.incomingBudget + elapsed * configuration.incomingRate)
        link.budgetUpdated = now
        guard link.incomingBudget >= 1 else { throw LinkFailure.protocolViolation }
        link.incomingBudget -= 1
        links[token] = link
    }

    private func trimHistory(_ id: ContactID) {
        guard let count = conversations[id]?.messages.count, count > Limits.maxStoredMessages,
              let dropped = conversations[id]?.messages.prefix(count - Limits.maxStoredMessages) else { return }
        conversations[id]?.messages.removeFirst(count - Limits.maxStoredMessages)
        forgetPhotos(of: Array(dropped))
    }

    func setStatus(_ status: DeliveryStatus, of messageID: UUID, in id: ContactID) {
        guard let index = conversations[id]?.messages.lastIndex(where: { $0.id == messageID }) else { return }
        conversations[id]?.messages[index].status = status
    }

    // MARK: Helpers

    func persist(_ id: ContactID) {
        guard let conversation = conversations[id] else { return }
        persistence.save(conversation: conversation, for: id, completion: nil)
    }

    private func updateRequest(_ token: PeerToken, _ change: (inout ConnectionRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == token }) else { return }
        change(&requests[index])
    }

    func after(_ delay: Duration, _ action: @escaping @MainActor (Messenger) -> Void) {
        let epoch = epoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.epoch == epoch else { return }
            action(self)
        }
    }

    /// Recomputes the state the interface reads from the internal link tables.
    func refresh() {
        var states: [ContactID: LinkState] = [:]
        for found in discovered.values where !found.isBlocked {
            if let id = found.contactID { states[id] = .inRange }
        }
        for link in links.values {
            if let id = link.contactID {
                states[id] = .connected
            } else if let expected = link.expected {
                states[expected] = max(states[expected] ?? .outOfRange, .connecting)
            }
        }
        if states != linkStates { linkStates = states }
        let photoCapable = Set(links.values.compactMap { link in
            link.peerFeatures.contains(Feature.photo) ? link.contactID : nil
        })
        if photoCapable != photoCapableContacts { photoCapableContacts = photoCapable }

        let peers = discovered.values.filter { !$0.isBlocked }.map { found in
            NearbyPeer(id: found.token,
                       displayName: found.contactID.flatMap(contact)?.displayName ?? found.name,
                       contactID: found.contactID)
        }.sorted { ($0.displayName.lowercased(), $0.id.rawValue) < ($1.displayName.lowercased(), $1.id.rawValue) }
        if peers != nearbyPeers { nearbyPeers = peers }
    }
}
