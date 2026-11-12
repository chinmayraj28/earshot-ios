import EarshotKit
import SwiftUI

/// One calm screen: what Earshot is doing, who is nearby, and your conversations.
struct HomeView: View {
    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router
    @State private var pendingAction: ConversationAction?

    enum ConversationAction: Identifiable {
        case clear(Contact)
        case remove(Contact)
        var id: String {
            switch self {
            case .clear(let contact): "clear-\(contact.id)"
            case .remove(let contact): "remove-\(contact.id)"
            }
        }
        var contact: Contact {
            switch self {
            case .clear(let contact), .remove(let contact): contact
            }
        }
    }

    private var isUnavailable: Bool {
        if case .unavailable = messenger.availability { return true }
        return false
    }

    /// People nearby who are not saved contacts yet.
    private var newPeople: [NearbyPeer] { messenger.nearbyPeers.filter { $0.contactID == nil } }

    /// Outgoing requests whose person is no longer detected nearby (so they still get a row).
    private var orphanedRequests: [ConnectionRequest] {
        let nearbyIDs = Set(newPeople.map(\.id))
        return messenger.requests.filter { $0.direction == .outgoing && !nearbyIDs.contains($0.id) }
    }

    var body: some View {
        List {
            StatusSection()

            if !isUnavailable {
                nearbySection
            }
            conversationsSection
        }
        .listStyle(.insetGrouped)
        .earshotList()
        .navigationTitle("Earshot")
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.3), value: messenger.nearbyPeers)
        .animation(.easeInOut(duration: 0.3), value: messenger.requests)
        .confirmationDialog(dialogTitle, isPresented: dialogBinding, titleVisibility: .visible, presenting: pendingAction) { action in
            switch action {
            case .clear(let contact):
                Button("Clear Conversation", role: .destructive) { messenger.clearConversation(contact.id) }
            case .remove(let contact):
                Button("Remove \(contact.displayName)", role: .destructive) { messenger.removeContact(contact.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .clear: Text("All messages with \(action.contact.displayName) will be deleted from this phone. \(action.contact.displayName.firstName) keeps their copy.")
            case .remove: Text("Deletes \(action.contact.displayName) and your messages from this phone. To talk again, one of you taps Connect and the other sees a normal request.")
            }
        }
    }

    private var dialogTitle: String {
        switch pendingAction {
        case .clear(let contact): "Clear conversation with \(contact.displayName)?"
        case .remove(let contact): "Remove \(contact.displayName)?"
        case nil: ""
        }
    }

    private var dialogBinding: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }

    // MARK: Nearby

    @ViewBuilder private var nearbySection: some View {
        Section {
            if newPeople.isEmpty && orphanedRequests.isEmpty {
                if messenger.availability == .on && messenger.nearbyPeers.isEmpty {
                    ListeningEmptyState()
                } else if messenger.availability == .on {
                    QuietNearbyRow()
                } else {
                    StartingRow()
                }
            } else {
                ForEach(newPeople) { peer in
                    NearbyPeerRow(name: peer.displayName, peer: peer,
                                  request: messenger.requests.first { $0.id == peer.id })
                }
                ForEach(orphanedRequests) { request in
                    NearbyPeerRow(name: request.displayName, peer: nil, request: request)
                }
            }
        } header: {
            SectionHeader("Nearby")
        } footer: {
            if !newPeople.isEmpty {
                Text("Connecting asks them first. Nothing is shared until they accept.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    // MARK: Conversations

    @ViewBuilder private var conversationsSection: some View {
        let summaries = messenger.conversationSummaries
        Section {
            if summaries.isEmpty {
                NoConversationsRow()
            } else {
                ForEach(summaries) { summary in
                    Button {
                        router.path.append(.chat(summary.id))
                    } label: {
                        ConversationRow(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.surface)
                    .accessibilityIdentifier("conversation.\(summary.contact.displayName)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            pendingAction = .remove(summary.contact)
                        } label: {
                            Label("Remove", systemImage: "person.crop.circle.badge.minus")
                        }
                        .tint(Palette.danger)
                        Button {
                            pendingAction = .clear(summary.contact)
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .tint(.gray)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            router.path.append(.contact(summary.id))
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                        .tint(Palette.accent)
                    }
                }
            }
        } header: {
            SectionHeader("Conversations")
        }
    }
}

/// Section titles in the display face, sentence case, not shouted.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.display(.title3, weight: .bold))
            .foregroundStyle(Palette.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, -4)
    }
}

#Preview("Home – populated") {
    let world = DemoWorld(scenario: .populated)
    return NavigationStack { HomeView() }
        .environment(world.messenger)
        .environment(AppRouter())
        .task { world.messenger.start() }
}
