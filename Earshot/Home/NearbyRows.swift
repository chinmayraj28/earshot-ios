import EarshotKit
import SwiftUI

/// The "listening" empty state: nobody running Earshot is close enough.
struct ListeningEmptyState: View {
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize: CGFloat = 132

    var body: some View {
        VStack(spacing: 18) {
            EarshotRings(animated: true)
                .frame(width: min(ringSize, 220), height: min(ringSize, 220))
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("Listening for people nearby")
                    .font(.display(.headline, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Nobody running Earshot is in range yet.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 10) {
                Tip(systemImage: "antenna.radiowaves.left.and.right", text: "Bluetooth on, on both phones")
                Tip(systemImage: "figure.walk", text: "Within about a room of each other")
                Tip(systemImage: "iphone.gen3", text: "Earshot opened on their phone, and not swiped away")
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Palette.surface)
    }

    private struct Tip: View {
        let systemImage: String
        let text: String
        @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Palette.accent)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Only saved contacts are around: say so quietly instead of the big empty state.
struct QuietNearbyRow: View {
    var body: some View {
        HStack(spacing: 12) {
            EarshotRings(animated: true)
                .frame(width: 28, height: 28)
            Text("No one new nearby. Contacts in range show a ring below.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .listRowBackground(Palette.surface)
        .accessibilityElement(children: .combine)
    }
}

struct StartingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Turning on…")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Palette.surface)
    }
}

/// A new person nearby, with Connect, and the state of any request to them.
struct NearbyPeerRow: View {
    let name: String
    /// Nil when the person has moved away but a request to them is still shown.
    let peer: NearbyPeer?
    let request: ConnectionRequest?

    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    Avatar(name: name, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                        statusText
                    }
                    .accessibilityElement(children: .combine)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                trailingControl
            }
            if case .failed = request?.state {
                failureActions
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nearby.peer.\(name)")
    }

    @ViewBuilder private var statusText: some View {
        Group {
            switch request?.state {
            case nil:
                Text(peer == nil ? "Moved away" : "Nearby · new")
            case .pending:
                Text("Wants to connect")
                    .foregroundStyle(Palette.accent)
            case .waiting:
                Text("Waiting for \(name.firstName) to accept…")
            case .connecting:
                Text("Connecting…")
            case .connected:
                Text("Connected")
            case .failed(let failure):
                Text(Self.failureText(failure, name: name))
                    .accessibilityIdentifier("nearby.failure.\(name)")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var trailingControl: some View {
        switch request?.state {
        case nil:
            if let peer {
                Button("Connect") { messenger.connect(to: peer) }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Connect with \(name)")
                    .accessibilityHint("Asks \(name.firstName) to start a conversation")
                    .accessibilityIdentifier("nearby.connect.\(name)")
            }
        case .pending:
            Button("Review") { if let request { router.presentedRequest = PresentedRequest(id: request.id) } }
                .buttonStyle(PillButtonStyle(kind: .tinted))
                .accessibilityLabel("Review request from \(name)")
        case .waiting:
            HStack(spacing: 8) {
                ProgressView()
                    .accessibilityHidden(true)
                Button("Cancel") { if let request { messenger.dismiss(request) } }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .accessibilityLabel("Cancel request to \(name)")
                    .accessibilityIdentifier("nearby.cancel.\(name)")
            }
        case .connecting, .connected:
            ProgressView()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Connecting")
        case .failed:
            EmptyView()
        }
    }

    private var failureActions: some View {
        HStack(spacing: 8) {
            if let peer {
                Button("Try Again") { messenger.connect(to: peer) }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Try connecting with \(name) again")
                    .accessibilityIdentifier("nearby.retry.\(name)")
            }
            Button("Dismiss") { if let request { messenger.dismiss(request) } }
                .buttonStyle(PillButtonStyle(kind: .tinted))
                .accessibilityLabel("Dismiss request to \(name)")
                .accessibilityIdentifier("nearby.dismiss.\(name)")
        }
    }

    static func failureText(_ failure: ConnectionRequest.Failure, name: String) -> String {
        let first = name.firstName
        return switch failure {
        case .noAnswer: "No answer. \(first) may have declined, missed it or moved away."
        case .connectionLost: "The connection dropped while setting up."
        case .verificationFailed: "Earshot couldn't confirm who this is, so nothing was shared."
        case .incompatibleVersion: "Your versions of Earshot don't match. You may both need to update."
        }
    }
}

struct NoConversationsRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No conversations yet")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text("When someone nearby accepts your request — or you accept theirs — your conversation appears here. It stays on this phone.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .listRowBackground(Palette.surface)
        .accessibilityElement(children: .combine)
    }
}
