import EarshotKit
import SwiftUI

/// Name, link state, last message, time and unread count for one contact.
struct ConversationRow: View {
    let summary: ConversationSummary
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(Messenger.self) private var messenger

    private var name: String { summary.contact.displayName }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Avatar(name: name, link: summary.link, size: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                HStack(alignment: .top, spacing: 8) {
                    preview
                    Spacer(minLength: 0)
                    if summary.unreadCount > 0 { unreadBadge }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the conversation")
        .accessibilityAddTraits(.isButton)
    }

    /// Name, link state and time on one line when they fit; otherwise the state moves under the name.
    @ViewBuilder private var titleLine: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                nameLabel(lineLimit: 3)
                if summary.link != .outOfRange { statusLabel }
                timeLabel
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    nameLabel(lineLimit: 1).fixedSize()
                    if summary.link != .outOfRange { statusLabel.fixedSize() }
                    Spacer(minLength: 4)
                    timeLabel.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        nameLabel(lineLimit: 2)
                        Spacer(minLength: 4)
                        timeLabel.fixedSize()
                    }
                    if summary.link != .outOfRange { statusLabel }
                }
            }
        }
    }

    private func nameLabel(lineLimit: Int) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.headline)
                .foregroundStyle(Palette.ink)
                .lineLimit(lineLimit)
            if summary.contact.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
            }
        }
    }

    private var statusLabel: some View {
        LinkStatusLabel(link: summary.link)
            .font(.caption.weight(.medium))
    }

    private var timeLabel: some View {
        TimelineView(.everyMinute) { context in
            Text(TimeFormat.short(summary.lastActivity, now: context.date))
                .font(.footnote)
                .foregroundStyle(summary.unreadCount > 0 ? Palette.accent : Palette.inkSecondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder private var preview: some View {
        if let message = summary.lastMessage {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon = statusIcon(message) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(message.status == .failed ? Palette.danger : Palette.inkSecondary)
                }
                Text(previewText(message))
                    .font(.subheadline)
                    .foregroundStyle(summary.unreadCount > 0 ? Palette.ink : Palette.inkSecondary)
                    .fontWeight(summary.unreadCount > 0 ? .medium : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        } else {
            Text("No messages yet — say hello")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(2)
        }
    }

    private var unreadBadge: some View {
        Text(summary.unreadCount > 99 ? "99+" : "\(summary.unreadCount)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Palette.accent, in: Capsule())
    }

    /// The list shows a message as it looks in the chat: formatting markers removed,
    /// and "Photo" for a photo (with its caption, if any).
    static func readableText(_ message: Message) -> String {
        let text = MessageFormatting.plainText(message.text).replacingOccurrences(of: "\n", with: " ")
        guard message.photo != nil else { return text }
        return text.isEmpty ? "Photo" : "Photo · \(text)"
    }

    /// Sealed for friends to carry (not delivered): how many friends' phones have a copy.
    private func handoffs(_ message: Message) -> Int? {
        message.direction == .outgoing && message.status == .waiting ? messenger.relayHandoffs[message.id] : nil
    }

    private func previewText(_ message: Message) -> String {
        let text = Self.readableText(message)
        guard message.direction == .outgoing else { return text }
        switch message.status {
        case .failed: return "Not delivered: \(text)"
        case .waiting: return handoffs(message) != nil ? "Waiting, sealed for friends: \(text)" : "Waiting: \(text)"
        case .delivered where message.relayed == true: return "You, via friends: \(text)"
        default: return "You: \(text)"
        }
    }

    private func statusIcon(_ message: Message) -> String? {
        if message.relayed == true { return "person.2" }
        guard message.direction == .outgoing else { return nil }
        switch message.status {
        case .waiting: return handoffs(message) != nil ? "envelope" : "clock"
        case .failed: return "exclamationmark.circle.fill"
        case .sending, .delivered: return nil
        }
    }

    private var accessibilityText: String {
        var parts = [name]
        if summary.contact.isVerified { parts.append("verified") }
        if summary.link != .outOfRange { parts.append(summary.link.label) }
        if summary.unreadCount > 0 {
            parts.append(summary.unreadCount == 1 ? "1 unread message" : "\(summary.unreadCount) unread messages")
        }
        if let message = summary.lastMessage {
            let who = message.direction == .outgoing ? "You" : name.firstName
            var line = "\(who): \(Self.readableText(message))"
            if message.direction == .outgoing {
                switch message.status {
                case .waiting where handoffs(message) != nil: line += ". Waiting, sealed for friends to carry"
                case .waiting: line += ". Waiting to send"
                case .failed: line += ". Not delivered"
                case .sending: line += ". Sending"
                case .delivered: if message.relayed == true { line += ". Delivered through friends" }
                }
            } else if message.relayed == true {
                line += ". Arrived through friends"
            }
            parts.append(line)
            parts.append(TimeFormat.spoken(message.timestamp))
        } else {
            parts.append("No messages yet")
        }
        return parts.joined(separator: ", ")
    }
}
