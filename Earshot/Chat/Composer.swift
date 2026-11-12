import EarshotKit
import PhotosUI
import SwiftUI

/// Whether a photo can be attached right now, and if not, why (in words for the person).
enum AttachAvailability: Equatable {
    case available
    /// Photos are only started while the two phones are linked.
    case notConnected(name: String)
    /// Their Earshot is a version without photos.
    case notSupported(name: String)

    var explanation: String? {
        switch self {
        case .available: nil
        case .notConnected(let name):
            "Photos can only be sent while you and \(name.firstName) are connected. Text messages wait and send later; photos don't."
        case .notSupported(let name):
            "\(name.firstName)'s Earshot can't receive photos yet. They need the latest version. Text works as usual."
        }
    }
}

/// The message field. Grows to five lines, then scrolls. Shows a counter as you
/// approach the length limit and explains (rather than truncates) when you pass it.
/// The photo button on the left picks a photo, which then waits above the field (with an
/// optional caption typed below) until Send.
struct Composer: View {
    @Binding var draft: String
    @Binding var staged: StagedPhoto?
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    var attach: AttachAvailability = .available
    /// Debug and demo builds (`-useSamplePhoto`): the photo button uses a built-in picture
    /// instead of opening the system picker, so UI tests can drive it.
    var useSamplePhoto = false
    let onSend: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showsAttachHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var count: Int { trimmed.count }
    private var overBy: Int { count - Limits.maxMessageLength }
    private var hasPhoto: Bool { staged?.photo != nil }
    private var canSend: Bool {
        guard overBy <= 0, staged?.isPreparing != true else { return false }
        return hasPhoto ? attach == .available : !trimmed.isEmpty
    }
    private var showCounter: Bool { count > Limits.maxMessageLength - 200 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let explanation = attach.explanation, showsAttachHelp || staged != nil {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.accentWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("chat.attachUnavailable")
                    .transition(.opacity)
            }
            if let staged {
                StagedPhotoChip(staged: staged) { self.staged = nil }
                    .transition(.opacity)
            }
            if showCounter {
                Text(overBy > 0
                     ? "\(overBy) characters over the limit"
                     : "\(count.formatted()) / \(Limits.maxMessageLength.formatted())")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(overBy > 0 ? Palette.danger : Palette.inkSecondary)
                    .accessibilityIdentifier("chat.counter")
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachButton

                TextField(hasPhoto ? "Add a caption" : placeholder, text: $draft, axis: .vertical)
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
                    .accessibilityLabel(hasPhoto ? "Caption" : "Message")
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
                .accessibilityLabel(hasPhoto ? "Send photo" : "Send")
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: staged)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsAttachHelp)
        .onChange(of: attach) { _, now in if now == .available { showsAttachHelp = false } }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            prepare(item)
        }
    }

    // MARK: Attaching

    @ViewBuilder private var attachButton: some View {
        let available = attach == .available
        if available && !useSamplePhoto {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) { AttachIcon(available: true) }
                .accessibilityLabel("Attach photo")
                .accessibilityHint("Choose a photo to send")
                .accessibilityIdentifier("chat.attach")
        } else {
            // Not disabled: tapping explains why photos are unavailable right now.
            Button {
                if attach == .available { useSample() } else { showsAttachHelp.toggle() }
            } label: { AttachIcon(available: available) }
                .accessibilityLabel("Attach photo")
                .accessibilityValue(attach == .available ? "" : "Unavailable")
                .accessibilityHint(attach.explanation ?? "Choose a photo to send")
                .accessibilityIdentifier("chat.attach")
        }
    }

    private func useSample() {
        staged = StagedPhoto(photo: DemoWorld.samplePhoto, error: DemoWorld.samplePhoto == nil ? "Couldn't make the sample photo" : nil)
    }

    /// Loads the picked photo and shrinks it on a background task.
    private func prepare(_ item: PhotosPickerItem) {
        staged = StagedPhoto(photo: nil, error: nil)
        Task {
            let original = try? await item.loadTransferable(type: Data.self)
            let result: Result<PreparedPhoto, Error> = await Task.detached(priority: .userInitiated) {
                guard let original else { return .failure(PhotoProcessing.Failure.unreadable) }
                return Result { try PhotoProcessing.prepare(.data(original)) }
            }.value
            // The person may have removed it, or picked another, meanwhile.
            guard staged?.isPreparing == true else { return }
            switch result {
            case .success(let photo): staged = StagedPhoto(photo: photo, error: nil)
            case .failure: staged = StagedPhoto(photo: nil, error: "Couldn't use that photo")
            }
        }
    }
}

private struct AttachIcon: View {
    let available: Bool

    var body: some View {
        Image(systemName: "photo")
            .font(.title3)
            .foregroundStyle(available ? Palette.accent : Palette.inkTertiary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
