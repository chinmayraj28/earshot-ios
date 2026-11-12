import EarshotKit
import Foundation

/// A row in the chat transcript: either a time separator or a message with its place in a group.
enum ChatItem: Identifiable, Equatable {
    case separator(Date)
    case message(Message, ChatItem.Position)

    struct Position: Equatable {
        /// First bubble in a run from the same side.
        var isFirst: Bool
        /// Last bubble in a run from the same side.
        var isLast: Bool
    }

    var id: String {
        switch self {
        case .separator(let date): "sep-\(date.timeIntervalSinceReferenceDate)"
        case .message(let message, _): message.id.uuidString
        }
    }

    /// Messages closer together than this, from the same side, are grouped.
    static let groupingWindow: TimeInterval = 5 * 60
    /// A time separator is shown on a new day, or after this long a pause.
    static let separatorGap: TimeInterval = 60 * 60

    static func build(from messages: [Message], calendar: Calendar = .current) -> [ChatItem] {
        var items: [ChatItem] = []
        items.reserveCapacity(messages.count + 4)
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil

            let needsSeparator = previous.map { needsBreak(between: $0, and: message, calendar: calendar) } ?? true
            if needsSeparator { items.append(.separator(message.timestamp)) }

            let isFirst = needsSeparator || previous.map { !groups($0, with: message) } ?? true
            let isLast = next.map { needsBreak(between: message, and: $0, calendar: calendar) || !groups(message, with: $0) } ?? true
            items.append(.message(message, Position(isFirst: isFirst, isLast: isLast)))
        }
        return items
    }

    private static func needsBreak(between a: Message, and b: Message, calendar: Calendar) -> Bool {
        !calendar.isDate(a.timestamp, inSameDayAs: b.timestamp) || b.timestamp.timeIntervalSince(a.timestamp) >= separatorGap
    }

    private static func groups(_ a: Message, with b: Message) -> Bool {
        a.direction == b.direction && b.timestamp.timeIntervalSince(a.timestamp) < groupingWindow
    }
}
