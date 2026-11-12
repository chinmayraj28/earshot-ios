import EarshotKit
import SwiftUI

/// A conversation with one contact.
struct ChatView: View {
    let contactID: ContactID

    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let contact = messenger.contact(contactID) {
            ChatContent(contact: contact)
        } else {
            ContentUnavailableView("Contact removed", systemImage: "person.crop.circle.badge.xmark",
                                   description: Text("This conversation is no longer on this phone."))
                .screenBackground()
        }
    }
}

private struct ChatContent: View {
    let contact: Contact

    @Environment(Messenger.self) private var messenger
    @Environment(NotificationManager.self) private var notifications
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var draft = ""
    /// Where the end of the transcript sits relative to the visible area; drives the jump button.
    @State private var bottomEdge: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var linkDroppedHere = false
    @State private var sentCount = 0
    @State private var staged: StagedPhoto?
    @State private var viewing: Message?
    @FocusState private var composerFocused: Bool
    private let useSamplePhoto = LaunchOptions().useSamplePhoto

    private let bottomID = "chat-bottom"
    private let scrollSpace = "chat-scroll"
    private var isAtBottom: Bool { viewportHeight == 0 || bottomEdge <= viewportHeight + 60 }

    private var messages: [Message] { messenger.messages(for: contact.id) }
    private var link: LinkState { messenger.linkState(for: contact.id) }
    private var lastOutgoingID: UUID? { messages.last { $0.direction == .outgoing }?.id }
    private var lastIncomingID: UUID? { messages.last { $0.direction == .incoming }?.id }
    private var arriving: [IncomingPhoto] { messenger.incomingPhotos[contact.id] ?? [] }
    /// Read from observable state so the button updates the moment the link changes.
    private var attach: AttachAvailability {
        if messenger.photoCapableContacts.contains(contact.id) { return .available }
        return link == .connected ? .notSupported(name: contact.displayName) : .notConnected(name: contact.displayName)
    }

    var body: some View {
        // Banner, transcript and composer are stacked rather than overlaid, so the transcript's
        // frame (not its insets) changes when they appear; that keeps bottom anchoring exact.
        VStack(spacing: 0) {
            ConnectionBanner(name: contact.displayName, link: link,
                             availability: messenger.availability, droppedHere: linkDroppedHere)
            if notifications.isOfferingPermission {
                NotificationOfferCard()
            }
            transcript
            if contact.isBlocked {
                BlockedFooter(contact: contact)
            } else {
                Composer(draft: $draft, staged: $staged,
                         placeholder: typeSize.isAccessibilitySize ? "Message" : "Message \(contact.displayName.firstName)",
                         focused: $composerFocused, attach: attach, useSamplePhoto: useSamplePhoto, onSend: send)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: link)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openDetails()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Contact details")
                .accessibilityIdentifier("chat.details")
            }
        }
        .toolbarBackground(Palette.background, for: .navigationBar)
        .fullScreenCover(item: $viewing) { message in
            PhotoViewer(message: message, senderName: contact.displayName) {
                messenger.deleteMessage(message.id, in: contact.id)
            }
            .environment(messenger)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: lastIncomingID) { old, new in
            old != nil && new != nil
        }
        .onChange(of: link) { old, new in
            if old == .connected && new == .outOfRange { linkDroppedHere = true }
            if new == .connected { linkDroppedHere = false }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: notifications.isOfferingPermission)
        .onAppear {
            messenger.setActiveConversation(contact.id)
            notifications.openConversation = contact.id
            notifications.clearDelivered(for: contact.id)
        }
        .onDisappear {
            messenger.setActiveConversation(nil)
            if notifications.openConversation == contact.id { notifications.openConversation = nil }
            composerFocused = false
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack: bottom anchoring with LazyVStack leaves gaps or lands mid-conversation
                // when row heights are estimated (very visible at large text sizes). Conversations here
                // are short-lived and local, so laying out every row is affordable.
                VStack(spacing: 0) {
                    ConversationIntro(name: contact.displayName, isVerified: contact.isVerified)
                        .padding(.bottom, 8)
                    ForEach(ChatItem.build(from: messages, arriving: arriving)) { item in
                        row(item)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.frame(in: .named(scrollSpace)).maxY
                        } action: { maxY in
                            bottomEdge = maxY
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .coordinateSpace(.named(scrollSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                // The keyboard (or a banner) shrank the transcript: if you were reading the end, stay there.
                let wasAtBottom = viewportHeight == 0 || bottomEdge <= viewportHeight + 60
                let shrank = newHeight < viewportHeight
                viewportHeight = newHeight
                if shrank && wasAtBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Keep messages out from under the navigation bar. On iOS 26 the bar adapts its
            // text colour to whatever is behind it, and a dark ember bubble flips the title to white.
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && !messages.isEmpty {
                    jumpToBottomButton(proxy)
                }
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard let last = messages.last else { return }
                // Follow new messages if you sent it, or if you were already reading the end.
                if last.direction == .outgoing || isAtBottom { scrollToBottom(proxy) }
            }
            .onChange(of: arriving.count) { old, new in
                if new > old && isAtBottom { scrollToBottom(proxy) }
            }
            .task {
                // The navigation bar slides in during the push (Home hides it), resizing the
                // transcript after its first layout. Re-pin to the newest message as it settles.
                for delay in [50, 300, 350] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: composerFocused) { _, focused in
                if focused { scrollToBottom(proxy, delay: .milliseconds(300)) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            openDetails()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .accessibilityIdentifier("chat.title")
                    if contact.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                LinkStatusLabel(link: contact.isBlocked ? .outOfRange : link)
                    .font(.caption)
                    .lineLimit(1)
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge) // the navigation bar has a fixed height, like system titles
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(contact.displayName)\(contact.isVerified ? ", verified" : ""), \(link.label)")
        .accessibilityHint("Shows contact details")
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .separator(let date):
            Text(TimeFormat.separator(date))
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
        case .message(let message, let position):
            let outgoing = message.direction == .outgoing
            let showStatus = outgoing && (message.id == lastOutgoingID || message.status != .delivered)
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 0) {
                    if outgoing { Spacer(minLength: typeSize.isAccessibilitySize ? 24 : 56) }
                    MessageBubble(message: message, position: position, senderName: contact.displayName,
                                  photoSource: message.photo == nil ? nil : messenger.photoSource(for: message),
                                  photoProgress: messenger.photoProgress[message.id],
                                  onRetry: { messenger.retry(message.id, in: contact.id) },
                                  onDelete: { withAnimation { messenger.deleteMessage(message.id, in: contact.id) } },
                                  onOpenPhoto: { composerFocused = false; viewing = message },
                                  onCancelPhoto: { messenger.cancelPhoto(message.id, in: contact.id) })
                    if !outgoing { Spacer(minLength: typeSize.isAccessibilitySize ? 24 : 56) }
                }
                if showStatus {
                    DeliveryStatusLine(status: message.status, contactName: contact.displayName,
                                       isLast: message.id == lastOutgoingID,
                                       isPhoto: message.photo != nil,
                                       progress: messenger.photoProgress[message.id],
                                       failure: messenger.photoFailures[message.id],
                                       onRetry: { messenger.retry(message.id, in: contact.id) })
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                        .transition(.opacity)
                }
            }
            .padding(.top, position.isFirst ? 10 : 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: message.status)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        case .incomingPhoto(let incoming):
            HStack(spacing: 0) {
                IncomingPhotoBubble(incoming: incoming, progress: messenger.photoProgress[incoming.id] ?? 0,
                                    senderName: contact.displayName)
                Spacer(minLength: typeSize.isAccessibilitySize ? 24 : 56)
            }
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Palette.separator))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .padding(16)
        .accessibilityLabel("Jump to latest message")
        .transition(.opacity)
    }

    // MARK: Actions

    /// Puts the keyboard away first, so it doesn't spring back when you return to the chat.
    private func openDetails() {
        composerFocused = false
        router.path.append(.contact(contact.id))
    }

    private func send() {
        if let photo = staged?.photo {
            // Only possible while connected to a phone that takes photos; if the link dropped a
            // moment ago this fails, and the photo stays in the composer with the explanation.
            guard messenger.sendPhoto(photo, caption: draft, to: contact.id) != nil else { return }
            staged = nil
        } else {
            guard messenger.send(draft, to: contact.id) != nil else { return }
        }
        draft = ""
        sentCount += 1
    }

    /// Brings the newest message into view.
    private func scrollToBottom(_ proxy: ScrollViewProxy, delay: Duration? = nil) {
        Task { @MainActor in
            if let delay { try? await Task.sleep(for: delay) }
            if reduceMotion {
                proxy.scrollTo(bottomID, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }
}

/// Shown at the top of every conversation.
private struct ConversationIntro: View {
    let name: String
    let isVerified: Bool

    var body: some View {
        VStack(spacing: 10) {
            Avatar(name: name, size: 56)
            Text(name)
                .font(.display(.headline, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Label {
                Text(isVerified
                     ? "Verified in person. Messages are end-to-end encrypted and stored only on your two phones."
                     : "Messages are end-to-end encrypted and stored only on your two phones.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.center)
            .labelStyle(CenteredLabelStyle())
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
    }

    private struct CenteredLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 4) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

/// A slim banner that appears only when messages can't go straight through.
private struct ConnectionBanner: View {
    let name: String
    let link: LinkState
    let availability: Availability
    let droppedHere: Bool

    private var message: String? {
        let first = name.firstName
        switch availability {
        case .unavailable:
            return "Earshot can't reach nearby phones right now. Messages will wait and send once it can."
        case .off:
            return nil
        case .on:
            switch link {
            case .connected, .connecting, .inRange:
                return nil
            case .outOfRange:
                return droppedHere
                    ? "\(first) moved out of range. Messages will wait and send when your phones are near each other again."
                    : "\(first) isn't nearby. Messages will wait and send when your phones are near each other again."
            }
        }
    }

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: droppedHere ? "wave.3.right" : "clock")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.accentWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.banner")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct BlockedFooter: View {
    let contact: Contact
    @Environment(Messenger.self) private var messenger

    var body: some View {
        VStack(spacing: 10) {
            Text("You blocked \(contact.displayName). Their phone can't link to yours or send you messages.")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Unblock") { messenger.setBlocked(false, for: contact.id) }
                .buttonStyle(PillButtonStyle(kind: .tinted))
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Palette.background)
        .overlay(alignment: .top) { Palette.separator.frame(height: 0.5) }
    }
}
