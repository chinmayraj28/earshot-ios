import EarshotKit
import SwiftUI
import UIKit

/// Settings › Range test: what the Bluetooth radio saw, live, to measure real-world range.
/// Walk away from a friend's phone with this open and watch the signal and the link.
struct RangeTestView: View {
    @Environment(RangeLog.self) private var log
    @State private var copied = false

    var body: some View {
        Group {
            if log.source == .unavailable {
                unavailable
            } else {
                content
            }
        }
        .navigationTitle("Range test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { log.startWatching() }
        .onDisappear { log.stopWatching() }
    }

    private var unavailable: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(Palette.inkTertiary)
                    .accessibilityHidden(true)
                Text("Range test needs Bluetooth")
                    .font(.display(.title3, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("This screen shows what Earshot's Bluetooth radio sees. It works on a real iPhone; this build is using a Wi‑Fi stand-in instead.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .accessibilityIdentifier("range.unavailable")
    }

    private var content: some View {
        List {
            Section {
                Label {
                    Text(log.source == .sample
                         ? "Sample events (demo mode). On an iPhone this log stays in memory on the phone and is never saved or sent."
                         : "This log stays in memory on this phone and is never saved or sent. Phone labels are random to this phone and mean nothing elsewhere.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(Palette.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("range.notice")
            }
            .listRowBackground(Palette.surface)

            Section {
                let linked = log.linkedNow
                if linked.isEmpty {
                    Text("No phones linked right now")
                        .foregroundStyle(Palette.inkSecondary)
                } else {
                    ForEach(linked) { phone in
                        HStack {
                            Label("Phone \(phone.peer)", systemImage: "iphone.gen3")
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 8)
                            if let rssi = phone.rssi {
                                SignalText(rssi: rssi)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let gap = log.longestGapBeforeReconnect {
                    HStack {
                        Text("Longest gap before reconnect")
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 8)
                        Text(RangeText.duration(gap))
                            .foregroundStyle(Palette.inkSecondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("range.longestGap")
                }
            } header: {
                SectionHeader("Linked now")
            }
            .listRowBackground(Palette.surface)

            Section {
                actions
                if log.events.isEmpty {
                    Text("No events yet. Keep this screen open and move closer to or further from another phone running Earshot.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("range.empty")
                } else {
                    ForEach(Array(log.events.enumerated().reversed()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                }
            } header: {
                SectionHeader("Events")
            } footer: {
                Text("Signal strength is a rough guide: strong is about −65 dBm or better, weak is below −80 dBm. Walls, bodies and phone cases change it a lot.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)
        }
        .listStyle(.insetGrouped)
        .earshotList()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = log.plainText
                copied = true
            }
            .buttonStyle(PillButtonStyle(kind: .tinted))
            .accessibilityLabel(copied ? "Copied" : "Copy log as text")
            .accessibilityIdentifier("range.copy")
            ShareLink(item: log.plainText) {
                Text("Share")
            }
            .buttonStyle(PillButtonStyle(kind: .tinted))
            .accessibilityLabel("Share log as text")
            .accessibilityIdentifier("range.share")
            Spacer(minLength: 0)
            Button("Clear") {
                log.clear()
                copied = false
            }
            .buttonStyle(PillButtonStyle(kind: .plain))
            .accessibilityLabel("Clear log")
            .accessibilityIdentifier("range.clear")
        }
        .disabled(log.events.isEmpty)
    }
}

private struct SignalText: View {
    let rssi: Int

    var body: some View {
        Text("\(rssi) dBm · \(RangeText.strength(rssi))")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Palette.inkSecondary)
            .accessibilityLabel("Signal \(-rssi) below zero dBm, \(RangeText.strength(rssi))")
    }
}

private struct EventRow: View {
    let event: LinkEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(RangeText.kind(event.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text(event.date.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { details }
                VStack(alignment: .leading, spacing: 2) { details }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("range.event")
    }

    @ViewBuilder private var details: some View {
        Text("Phone \(event.peer)")
        if let rssi = event.rssi {
            Text("\(rssi) dBm · \(RangeText.strength(rssi))")
                .monospacedDigit()
                .accessibilityLabel("Signal \(-rssi) below zero dBm, \(RangeText.strength(rssi))")
        }
        Label(event.appState == .foreground ? "Open" : "In background",
              systemImage: event.appState == .foreground ? "iphone.gen3" : "moon")
            .labelStyle(.titleAndIcon)
    }
}
