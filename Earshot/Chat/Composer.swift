import EarshotKit
import SwiftUI

/// The message field. Grows to five lines, then scrolls. Shows a counter as you
/// approach the length limit and explains (rather than truncates) when you pass it.
struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var count: Int { trimmed.count }
    private var overBy: Int { count - Limits.maxMessageLength }
    private var canSend: Bool { !trimmed.isEmpty && overBy <= 0 }
    private var showCounter: Bool { count > Limits.maxMessageLength - 200 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if showCounter {
                Text(overBy > 0
                     ? "\(overBy) characters over the limit"
                     : "\(count.formatted()) / \(Limits.maxMessageLength.formatted())")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(overBy > 0 ? Palette.danger : Palette.inkSecondary)
                    .accessibilityIdentifier("chat.counter")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...5)
                    .focused(focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(overBy > 0 ? Palette.danger : Palette.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("chat.composer")

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? Palette.onAccent : Palette.inkSecondary)
                        .frame(width: 44, height: 44)
                        .background(canSend ? Palette.accent : Palette.surfaceSunken, in: Circle())
                }
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
                .accessibilityLabel("Send")
                .accessibilityHint(overBy > 0 ? "Message is too long" : "")
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            Palette.background
                .opacity(0.96)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Palette.separator.frame(height: 0.5) }
        }
    }
}
