import EarshotKit
import SwiftUI

/// Someone nearby wants to start a conversation. Calm, clear, two choices.
/// Stays up while the link is set up; closes itself when the chat opens.
struct IncomingRequestSheet: View {
    let requestID: PeerToken

    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Remembered so the sheet can still say who it was after the request is gone.
    @State private var lastKnownName = ""

    private var request: ConnectionRequest? { messenger.requests.first { $0.id == requestID } }
    private var otherPendingCount: Int {
        messenger.requests.filter { $0.direction == .incoming && $0.state == .pending && $0.id != requestID }.count
    }

    var body: some View {
        let name = request?.displayName ?? lastKnownName
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    EarshotRings(animated: request?.state == .pending || request?.state == .connecting)
                        .frame(width: 150, height: 150)
                    Avatar(name: name, size: 64)
                }
                .padding(.top, 20)

                VStack(spacing: 8) {
                    Text(title(name))
                        .font(.display(.title2, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("request.title")
                    Text(detail(name))
                        .font(.body)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions(name)

                if otherPendingCount > 0, request?.state == .pending {
                    Text(otherPendingCount == 1 ? "1 more request waiting" : "\(otherPendingCount) more requests waiting")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .presentationDetents(typeSize >= .xxLarge ? [.large] : [.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        // A pending request needs an explicit answer; afterwards the sheet can be swiped away.
        .interactiveDismissDisabled(request?.state == .pending || request?.state == .connecting)
        .onAppear { if let request { lastKnownName = request.displayName } }
        .onChange(of: request?.displayName) { _, newName in if let newName { lastKnownName = newName } }
        .onDisappear {
            // Swiped away after a failure: clear it from the engine too.
            if let request, request.state != .pending, request.state != .connecting { messenger.dismiss(request) }
        }
        .animation(.easeInOut(duration: 0.25), value: request?.state)
    }

    private func title(_ name: String) -> String {
        guard let request else { return "This request has ended" }
        return switch request.state {
        case .pending, .waiting: "\(name) wants to connect"
        case .connecting, .connected: "Connecting to \(name)…"
        case .failed: "Couldn't connect to \(name)"
        }
    }

    private func detail(_ name: String) -> String {
        switch request?.state {
        case .pending:
            "If you accept, you can send each other messages whenever your phones are near each other. \(name.firstName) will be saved as a contact on this phone."
        case .connecting, .connected:
            "Setting up an encrypted link. This only takes a moment."
        case .failed(let failure):
            switch failure {
            case .noAnswer, .connectionLost: "\(name.firstName) may have moved out of range. If they're still nearby, they can send a new request."
            case .verificationFailed: "Earshot couldn't confirm who this is, so nothing was shared."
            case .incompatibleVersion: "Your versions of Earshot don't match. You may both need to update."
            }
        default:
            "\(name.isEmpty ? "They" : name.firstName) may have moved away or cancelled. If they're still nearby, they can send a new request."
        }
    }

    @ViewBuilder private func actions(_ name: String) -> some View {
        switch request?.state {
        case .pending:
            VStack(spacing: 10) {
                Button("Accept") {
                    if let request { messenger.accept(request) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Accept request from \(name)")
                .accessibilityIdentifier("request.accept")

                Button {
                    if let request { messenger.decline(request) }
                    router.finishPresentedRequest(messenger: messenger)
                } label: {
                    Text("Decline")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Palette.accent)
                .accessibilityLabel("Decline request from \(name)")
                .accessibilityHint("\(name.firstName) won't be told you declined")
                .accessibilityIdentifier("request.decline")

                Text("If you decline, \(name.firstName) just sees that you didn't answer.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        case .connecting, .connected:
            ProgressView()
                .controlSize(.large)
                .frame(minHeight: 54)
        default:
            Button("Close") {
                if let request { messenger.dismiss(request) }
                router.finishPresentedRequest(messenger: messenger)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("request.close")
        }
    }
}
