import EarshotKit
import SwiftUI
import UIKit

/// One message bubble. Outgoing is ember, incoming is a warm neutral.
/// The corner nearest the sender is tucked in to show who is speaking and
/// to join consecutive bubbles into a group.
struct MessageBubble: View {
    let message: Message
    let position: ChatItem.Position
    let senderName: String
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var isOutgoing: Bool { message.direction == .outgoing }

    var body: some View {
        Text(message.text)
            .font(.body)
            .foregroundStyle(isOutgoing ? Palette.onBubbleOutgoing : Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isOutgoing ? Palette.bubbleOutgoing : Palette.bubbleIncoming, in: shape)
            .opacity(message.status == .failed ? 0.75 : 1)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if isOutgoing && message.status == .failed {
                    Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete from This Phone", systemImage: "trash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(isOutgoing ? "You" : senderName): \(message.text)")
            .accessibilityValue(message.timestamp.formatted(date: .omitted, time: .shortened))
            .accessibilityAction(named: "Copy") { UIPasteboard.general.string = message.text }
            .accessibilityAction(named: "Delete from this phone", onDelete)
            .accessibilityIdentifier("chat.bubble")
    }

    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 20, small: CGFloat = 6
        let senderTop = position.isFirst ? big : small
        let senderBottom = small
        return isOutgoing
            ? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big,
                                     bottomTrailingRadius: senderBottom, topTrailingRadius: senderTop, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: senderTop, bottomLeadingRadius: senderBottom,
                                     bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
}

/// The line under an outgoing message: Sending… / Delivered / Waiting… / Not delivered.
struct DeliveryStatusLine: View {
    let status: DeliveryStatus
    let contactName: String
    let isLast: Bool
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch status {
            case .waiting:
                Label("Waiting for \(contactName.firstName) to be nearby", systemImage: "clock")
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityLabel("Waiting for \(contactName.firstName) to be nearby. Sends automatically.")
            case .sending:
                Text("Sending…")
                    .foregroundStyle(Palette.inkSecondary)
            case .delivered:
                Text("Delivered")
                    .foregroundStyle(Palette.inkSecondary)
            case .failed:
                Button(action: onRetry) {
                    Label("Not delivered · Tap to retry", systemImage: "exclamationmark.circle.fill")
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.danger)
                .accessibilityLabel("Not delivered")
                .accessibilityHint("No receipt came back. Double-tap to try sending again")
            }
        }
        .font(.caption)
        .labelStyle(StatusLabelStyle())
        .multilineTextAlignment(.trailing)
        .accessibilityIdentifier(isLast ? "chat.lastStatus" : "chat.status")
    }

    private struct StatusLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}
