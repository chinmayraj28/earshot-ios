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
    var photoSource: PhotoSource? = nil
    var photoProgress: Double? = nil
    let onRetry: () -> Void
    let onDelete: () -> Void
    var onOpenPhoto: () -> Void = {}
    var onCancelPhoto: () -> Void = {}

    @Environment(\.openURL) private var openURL

    private var isOutgoing: Bool { message.direction == .outgoing }
    private var links: [URL] { MessageFormatting.links(in: message.text) }

    var body: some View {
        content
            .background(isOutgoing ? Palette.bubbleOutgoing : Palette.bubbleIncoming, in: shape)
            .opacity(message.status == .failed ? 0.75 : 1)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu { menu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(message.timestamp.formatted(date: .omitted, time: .shortened))
            .accessibilityAddTraits(message.photo != nil ? [.isImage] : [])
            .accessibilityHint(message.photo != nil ? "Double-tap to view full screen" : "")
            .modifier(OpenPhotoAction(isPhoto: message.photo != nil, open: onOpenPhoto))
            .accessibilityActions {
                // Each link is its own action, so VoiceOver users can open or copy it.
                ForEach(links, id: \.self) { url in
                    Button("Open \(MessageFormatting.label(for: url, in: message.text))") { openURL(url) }
                }
                if !message.text.isEmpty {
                    Button("Copy") { UIPasteboard.general.string = message.text }
                }
                if isOutgoing && message.photo != nil && (message.status == .sending || message.status == .waiting) {
                    Button("Cancel sending", action: onCancelPhoto)
                }
                Button("Delete from this phone", action: onDelete)
            }
            .accessibilityIdentifier(message.photo != nil ? "chat.photoBubble" : "chat.bubble")
    }

    @ViewBuilder private var content: some View {
        if let photo = message.photo {
            PhotoBubbleContent(message: message, photo: photo, source: photoSource, progress: photoProgress,
                               imageShape: imageShape, onOpen: onOpenPhoto, onCancel: onCancelPhoto)
        } else {
            FormattedText(text: message.text, isOutgoing: isOutgoing)
                .font(.body)
                .foregroundStyle(isOutgoing ? Palette.onBubbleOutgoing : Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
    }

    @ViewBuilder private var menu: some View {
        if message.photo != nil {
            Button(action: onOpenPhoto) { Label("View Photo", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
        if !message.text.isEmpty {
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label(message.photo == nil ? "Copy" : "Copy Caption", systemImage: "doc.on.doc")
            }
        }
        ForEach(links, id: \.self) { url in
            Button {
                UIPasteboard.general.string = Self.copyText(for: url)
            } label: {
                Label("Copy \(MessageFormatting.label(for: url, in: message.text))", systemImage: "link")
            }
        }
        if isOutgoing && message.photo != nil && (message.status == .sending || message.status == .waiting) {
            Button(action: onCancelPhoto) { Label("Cancel Sending", systemImage: "xmark.circle") }
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

    /// What "Copy link" puts on the clipboard: the address itself, without `mailto:` or `tel:`.
    static func copyText(for url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto", "tel": String(url.absoluteString.drop { $0 != ":" }.dropFirst())
        default: url.absoluteString
        }
    }

    /// What VoiceOver reads: who, then the message as it looks (markers removed).
    private var accessibilityText: String {
        let who = isOutgoing ? "You" : senderName
        let text = MessageFormatting.plainText(message.text)
        guard message.photo != nil else { return "\(who): \(text)" }
        var line = "\(who): Photo"
        if !text.isEmpty { line += ". \(text)" }
        if let photoProgress, isOutgoing, message.status == .sending {
            line += ". Sending, \(Int(photoProgress * 100)) percent"
        }
        return line
    }

    /// The picture follows the bubble's corners; with a caption under it, its bottom is square.
    private var imageShape: UnevenRoundedRectangle {
        guard !message.text.isEmpty else { return shape }
        var top = shape
        top.cornerRadii.bottomLeading = 0
        top.cornerRadii.bottomTrailing = 0
        return top
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
/// For photos it also shows how far the photo has got, and why it failed when known.
struct DeliveryStatusLine: View {
    let status: DeliveryStatus
    let contactName: String
    let isLast: Bool
    var isPhoto = false
    var progress: Double? = nil
    var failure: PhotoFailure? = nil
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch status {
            case .waiting:
                Label("Waiting for \(contactName.firstName) to be nearby", systemImage: "clock")
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityLabel(isPhoto
                        ? "Waiting for \(contactName.firstName) to be nearby. The photo starts again when you're connected."
                        : "Waiting for \(contactName.firstName) to be nearby. Sends automatically.")
            case .sending:
                if isPhoto, let progress {
                    Text("Sending photo… \(Int((progress * 100).rounded(.down)))%")
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                } else if isPhoto {
                    Text("Waiting for the photo before it…")
                        .foregroundStyle(Palette.inkSecondary)
                } else {
                    Text("Sending…")
                        .foregroundStyle(Palette.inkSecondary)
                }
            case .delivered:
                Text("Delivered")
                    .foregroundStyle(Palette.inkSecondary)
            case .failed:
                if failure == .notSupported {
                    Label("Not delivered · \(contactName.firstName)'s Earshot can't receive photos yet",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Palette.danger)
                } else {
                    Button(action: onRetry) {
                        Label(failureText, systemImage: "exclamationmark.circle.fill")
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.danger)
                    .accessibilityLabel(failure == .cancelled ? "Cancelled" : "Not delivered")
                    .accessibilityHint(failureHint)
                }
            }
        }
        .font(.caption)
        .labelStyle(StatusLabelStyle())
        .multilineTextAlignment(.trailing)
        .accessibilityIdentifier(isLast ? "chat.lastStatus" : "chat.status")
    }

    private var failureText: String {
        switch failure {
        case .cancelled: "Cancelled · Tap to retry"
        case .refused: "Not delivered · Their phone didn't accept it · Tap to retry"
        case .stalled: "Not delivered · The connection stalled · Tap to retry"
        case .missingFile: "Not delivered · The photo is missing"
        case .notSupported, nil: "Not delivered · Tap to retry"
        }
    }

    private var failureHint: String {
        switch failure {
        case .refused: "Their phone may be out of space. Double-tap to try again"
        case .stalled: "The connection stopped making progress. Double-tap to try again"
        default: "No receipt came back. Double-tap to try sending again"
        }
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

/// For photo bubbles only: VoiceOver's double-tap opens the photo full screen.
/// Text bubbles get no default action, so they are not announced as buttons.
private struct OpenPhotoAction: ViewModifier {
    let isPhoto: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if isPhoto {
            content.accessibilityAction(.default, open)
        } else {
            content
        }
    }
}
