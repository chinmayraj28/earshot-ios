import EarshotKit
import Foundation
import Observation

/// The Bluetooth link events shown on the Range test screen.
///
/// On a real iPhone they come from `BluetoothTransport` (an in-memory ring buffer of the last
/// 500 events, never saved or sent). In demo mode a fixed sample is shown so the screen can be
/// screenshotted and tested. In the Simulator (which uses a Wi‑Fi stand-in) there is nothing to show.
@MainActor
@Observable
final class RangeLog {
    enum Source: Equatable {
        case bluetooth
        case sample
        case unavailable
    }

    struct LinkedPhone: Identifiable, Equatable {
        let peer: String
        let rssi: Int?
        let since: Date
        var id: String { peer }
    }

    let source: Source
    /// Oldest first, like the transport's buffer.
    private(set) var events: [LinkEvent] = []

    @ObservationIgnored private weak var transport: BluetoothTransport?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    private static let maxEvents = 500

    init(transport: Transport?, demo: Bool) {
        if demo {
            source = .sample
            events = Self.sampleEvents(now: Date())
        } else if let bluetooth = transport as? BluetoothTransport {
            source = .bluetooth
            self.transport = bluetooth
        } else {
            source = .unavailable
        }
    }

    /// Reads the backlog and follows new events while the screen is open.
    func startWatching() {
        guard source == .bluetooth, let transport, watcher == nil else { return }
        events = transport.diagnostics()
        let stream = transport.linkEvents()
        watcher = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.events.append(event)
                if self.events.count > Self.maxEvents { self.events.removeFirst(self.events.count - Self.maxEvents) }
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    func clear() {
        transport?.clearDiagnostics()
        events.removeAll()
    }

    // MARK: Summary

    /// Phones whose engine link is up, judged from the events, with the latest signal reading.
    var linkedNow: [LinkedPhone] {
        var linkedSince: [String: Date] = [:]
        var latestSignal: [String: Int] = [:]
        for event in events {
            if let rssi = event.rssi { latestSignal[event.peer] = rssi }
            switch event.kind {
            case .linkUp: linkedSince[event.peer] = event.date
            case .linkDown, .disconnected, .connectFailed: linkedSince[event.peer] = nil
            default: break
            }
        }
        return linkedSince.map { LinkedPhone(peer: $0.key, rssi: latestSignal[$0.key], since: $0.value) }
            .sorted { $0.peer < $1.peer }
    }

    /// The longest time any phone was gone between losing its link and linking again.
    var longestGapBeforeReconnect: TimeInterval? {
        var droppedAt: [String: Date] = [:]
        var linked: Set<String> = []
        var longest: TimeInterval?
        for event in events {
            switch event.kind {
            case .linkUp:
                if let dropped = droppedAt.removeValue(forKey: event.peer) {
                    let gap = event.date.timeIntervalSince(dropped)
                    longest = max(longest ?? 0, gap)
                }
                linked.insert(event.peer)
            case .linkDown, .disconnected:
                if linked.remove(event.peer) != nil { droppedAt[event.peer] = event.date }
            default:
                break
            }
        }
        return longest
    }

    /// The whole log as plain text, for Copy and the share sheet.
    var plainText: String {
        let lines = events.map { event in
            [event.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)),
             RangeText.kind(event.kind), "phone \(event.peer)",
             event.rssi.map { "\($0) dBm (\(RangeText.strength($0)))" } ?? "no signal reading",
             event.appState == .foreground ? "foreground" : "background"].joined(separator: "  ")
        }
        return (["Earshot range test — \(Date().formatted(date: .abbreviated, time: .shortened))",
                 "Phone labels are random to this phone; no names, keys or messages are included.", ""] + lines)
            .joined(separator: "\n")
    }

    // MARK: Demo sample

    /// A walk away from one phone and back, plus a second phone that needed a retry.
    static func sampleEvents(now: Date) -> [LinkEvent] {
        let start = now.addingTimeInterval(-7 * 60)
        typealias Step = (seconds: Double, kind: LinkEvent.Kind, peer: String, rssi: Int?, background: Bool)
        let steps: [Step] = [
            (0, .discovered, "a3f1", -58, false),
            (1, .connectRequested, "a3f1", nil, false),
            (2, .connected, "a3f1", -59, false),
            (3, .linkUp, "a3f1", nil, false),
            (30, .discovered, "7c02", -81, false),
            (31, .connectRequested, "7c02", nil, false),
            (51, .connectFailed, "7c02", nil, false),
            (56, .reconnecting, "7c02", nil, false),
            (64, .connected, "7c02", -78, false),
            (65, .linkUp, "7c02", nil, false),
            (90, .signal, "a3f1", -63, false),
            (150, .signal, "a3f1", -71, false),
            (190, .signal, "a3f1", -79, true),
            (215, .signal, "a3f1", -86, true),
            (231, .linkDown, "a3f1", nil, true),
            (231, .disconnected, "a3f1", nil, true),
            (232, .reconnecting, "a3f1", nil, true),
            (300, .connected, "a3f1", -74, false),
            (301, .linkUp, "a3f1", nil, false),
            (330, .signal, "7c02", -76, false),
            (360, .signal, "a3f1", -66, false),
            (400, .signal, "a3f1", -61, false),
        ]
        return steps.map {
            LinkEvent(date: start.addingTimeInterval($0.seconds), kind: $0.kind, peer: $0.peer, rssi: $0.rssi,
                      appState: $0.background ? .background : .foreground)
        }
    }
}

/// Plain-language wording for link events.
enum RangeText {
    static func kind(_ kind: LinkEvent.Kind) -> String {
        switch kind {
        case .discovered: "Found nearby"
        case .connectRequested: "Asked to connect"
        case .connected: "Bluetooth connected"
        case .linkUp: "Linked"
        case .linkDown: "Link ended"
        case .disconnected: "Bluetooth disconnected"
        case .connectFailed: "Connection failed"
        case .reconnecting: "Reconnecting"
        case .signal: "Signal reading"
        }
    }

    /// A rough reading of Bluetooth signal strength. Walls, bodies and phone cases move these a lot.
    static func strength(_ rssi: Int) -> String {
        switch rssi {
        case (-65)...: "strong"
        case (-80)...: "fair"
        default: "weak"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
