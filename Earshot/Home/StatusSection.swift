import EarshotKit
import SwiftUI
import UIKit

/// The top of Home: the wordmark, a one-line summary of what Earshot is doing,
/// and — when it cannot look for people — a clear explanation with a fix.
struct StatusSection: View {
    @Environment(Messenger.self) private var messenger

    var body: some View {
        Section {
            HomeHeader()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
        .listSectionSpacing(.compact)

        if case .unavailable(let problem) = messenger.availability {
            Section { ProblemCard(problem: problem) }
                .listRowBackground(Palette.surface)
        }
    }
}

/// "Earshot" with the rings mark, Settings, and "Listening nearby · Visible as Alex"
/// (or the hidden state with a way back).
private struct HomeHeader: View {
    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 34

    var body: some View {
        let visible = messenger.profile.isVisible
        let on = messenger.availability == .on
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                EarshotRings(animated: on && visible && !messenger.nearbyPeers.isEmpty,
                             color: on && visible ? Palette.signal : Palette.inkTertiary)
                    .frame(width: min(markSize, 56), height: min(markSize, 56))
                Text("Earshot")
                    .font(.display(.largeTitle, weight: .heavy))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    router.path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .background(Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.settings")
            }
            if case .unavailable = messenger.availability {
                EmptyView()
            } else {
                statusLine(on: on, visible: visible)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder private func statusLine(on: Bool, visible: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? (visible ? "Listening nearby" : "Hidden from people nearby") : "Turning on…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(visible ? "Visible as \(messenger.profile.displayName)" : "You can still find people. New people can't see you.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if !visible {
                Button("Show Me") { messenger.setVisible(true) }
                    .buttonStyle(PillButtonStyle(kind: .tinted))
                    .accessibilityHint("Makes you visible to people nearby")
                    .accessibilityIdentifier("home.becomeVisible")
            }
        }
        .padding(.trailing, 8)
    }
}

/// Explains why Earshot can't look for people right now, and how to fix it.
/// The engine starts again by itself once Bluetooth is switched on or allowed.
private struct ProblemCard: View {
    let problem: TransportProblem

    var body: some View {
        switch problem {
        case .bluetoothDenied:
            SimpleProblemCard(systemImage: "antenna.radiowaves.left.and.right.slash",
                              title: "Earshot needs Bluetooth",
                              detail: "Bluetooth access is turned off for Earshot. It's how Earshot reaches phones around you — nothing goes to the internet.",
                              fix: "Open Settings, then turn on **Bluetooth**. Earshot starts again by itself.",
                              opensSettings: true)
        case .bluetoothOff:
            SimpleProblemCard(systemImage: "antenna.radiowaves.left.and.right.slash",
                              title: "Bluetooth is off",
                              detail: "Earshot needs Bluetooth to reach phones nearby. It can stay on in Airplane Mode.",
                              fix: "Open Control Center and tap the Bluetooth button, or go to Settings › Bluetooth. Earshot starts again by itself.",
                              opensSettings: false)
        case .bluetoothUnsupported:
            SimpleProblemCard(systemImage: "exclamationmark.triangle",
                              title: "Bluetooth isn't available",
                              detail: "This device has no Bluetooth radio Earshot can use, so it can't reach phones nearby.",
                              fix: nil,
                              opensSettings: false)
        case .localNetworkDenied:
            // Only possible in the Simulator, which uses Wi-Fi instead of Bluetooth.
            SimpleProblemCard(systemImage: "wifi.exclamationmark",
                              title: "Local Network access is off (Simulator)",
                              detail: "In the Simulator Earshot uses the local network instead of Bluetooth.",
                              fix: "Open Settings, then turn on **Local Network**.",
                              opensSettings: true)
        case .failedToStart(let message):
            StartFailedCard(message: message)
        }
    }
}

private struct SimpleProblemCard: View {
    let systemImage: String
    let title: String
    let detail: String
    let fix: LocalizedStringKey?
    let opensSettings: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Palette.danger)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fix {
                Text(fix)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint("Opens Earshot's page in the Settings app")
            }
        }
        .padding(.vertical, 8)
    }
}

/// The engine couldn't start. Its message says why (a radio problem, or for example that
/// this phone's identity key couldn't be read), so it is shown as is.
private struct StartFailedCard: View {
    let message: String
    @Environment(Messenger.self) private var messenger

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Earshot couldn't start")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Palette.danger)
            }
            Text(message.isEmpty ? "Something went wrong while starting. Try again in a moment." : message)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { messenger.start() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("home.retryStart")
        }
        .padding(.vertical, 8)
    }
}
