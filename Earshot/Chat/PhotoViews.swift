import EarshotKit
import SwiftUI
import UIKit

// MARK: Loading

/// Decodes stored photos off the main thread, at the size they are shown, and keeps a few
/// recent ones in memory. Uses `PhotoProcessing.decode`, which checks an image's real size
/// before unpacking it, so no file can make the app allocate a huge picture.
@MainActor
final class PhotoLoader {
    static let shared = PhotoLoader()
    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 40 }

    func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func load(_ source: PhotoSource, key: String, maxPixelSize: Int) async -> UIImage? {
        let cacheKey = "\(key)@\(maxPixelSize)"
        if let hit = cached(cacheKey) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            PhotoProcessing.decode(source, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: cacheKey as NSString) }
        return image
    }
}

/// A stored photo, filled to its frame. Shows a soft placeholder while decoding.
struct StoredPhotoImage: View {
    let source: PhotoSource?
    let key: String
    var maxPixelSize = 900
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Palette.surfaceSunken
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || source == nil {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .task(id: key) {
            guard let source else { return }
            if let hit = PhotoLoader.shared.cached("\(key)@\(maxPixelSize)") { image = hit; return }
            image = await PhotoLoader.shared.load(source, key: key, maxPixelSize: maxPixelSize)
            failed = image == nil
        }
    }
}

// MARK: Sizing

enum PhotoLayout {
    static let maxWidth: CGFloat = 240
    static let minHeight: CGFloat = 110
    static let maxHeight: CGFloat = 320

    /// Keeps the photo's real proportions, within sensible bounds for a chat bubble.
    static func size(width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.75) }
        let ratio = CGFloat(height) / CGFloat(width)
        var w = maxWidth, h = maxWidth * ratio
        if h > maxHeight { h = maxHeight; w = max(maxHeight / ratio, 120) }
        return CGSize(width: w, height: max(h, minHeight))
    }
}

// MARK: Progress

/// A ring that fills as a photo travels, with the percentage in the middle.
struct TransferRing: View {
    let progress: Double?
    var size: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45))
            Circle().stroke(.white.opacity(0.3), lineWidth: 4).padding(5)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress)
                Text("\(Int((progress * 100).rounded(.down)))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Bubbles

/// A photo message: the picture at its real shape, an optional caption under it, and,
/// while sending, a progress ring with a cancel button.
struct PhotoBubbleContent: View {
    let message: Message
    let photo: PhotoAttachment
    let source: PhotoSource?
    let progress: Double?
    let imageShape: UnevenRoundedRectangle
    let onOpen: () -> Void
    let onCancel: () -> Void

    private var isOutgoing: Bool { message.direction == .outgoing }
    private var isSending: Bool { isOutgoing && message.status == .sending }

    var body: some View {
        let size = PhotoLayout.size(width: photo.width, height: photo.height)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                StoredPhotoImage(source: source, key: photo.fileName)
                    .frame(width: size.width, height: size.height)
                    .clipShape(imageShape)
                    .overlay {
                        if isSending { TransferRing(progress: progress) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSending {
                            Button(action: onCancel) {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(.black.opacity(0.5), in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Cancel sending photo")
                            .accessibilityIdentifier("chat.photo.cancel")
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.photo")

            if !message.text.isEmpty {
                FormattedText(text: message.text, isOutgoing: isOutgoing)
                    .font(.body)
                    .foregroundStyle(isOutgoing ? Palette.onBubbleOutgoing : Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A photo that is still arriving: the sender's tiny preview, blurred, under a progress ring.
struct IncomingPhotoBubble: View {
    let incoming: IncomingPhoto
    let progress: Double
    let senderName: String

    @State private var preview: UIImage?

    var body: some View {
        let size = PhotoLayout.size(width: incoming.width, height: incoming.height)
        ZStack {
            Palette.surfaceSunken
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill().blur(radius: 14).opacity(0.9)
            }
            TransferRing(progress: progress)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6, bottomTrailingRadius: 20,
                                          topTrailingRadius: 20, style: .continuous))
        .task(id: incoming.id) {
            guard let data = incoming.preview else { return }
            preview = await PhotoLoader.shared.load(.data(data), key: "preview-\(incoming.id)", maxPixelSize: 64)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(senderName.firstName) is sending you a photo")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityIdentifier("chat.incomingPhoto")
    }
}

// MARK: Composer attachment

/// The photo picked for the next message, shown above the text field until it is sent.
struct StagedPhoto: Equatable {
    var photo: PreparedPhoto?
    var isPreparing: Bool { photo == nil && error == nil }
    var error: String?
}

struct StagedPhotoChip: View {
    let staged: StagedPhoto
    let onRemove: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Palette.surfaceSunken
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else if staged.isPreparing {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.danger)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(staged.error == nil ? Palette.ink : Palette.danger)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.staged")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Remove photo")
            .accessibilityIdentifier("chat.staged.remove")
        }
        .padding(8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.separator))
        .task(id: staged.photo?.jpeg.count) {
            guard let jpeg = staged.photo?.jpeg else { thumbnail = nil; return }
            thumbnail = await PhotoLoader.shared.load(.data(jpeg), key: "staged-\(jpeg.hashValue)", maxPixelSize: 168)
        }
    }

    private var title: String {
        if let error = staged.error { return error }
        return staged.isPreparing ? "Preparing photo…" : "Photo ready to send"
    }

    private var detail: String {
        guard let photo = staged.photo else {
            return staged.error == nil ? "Making it small enough for Bluetooth." : "Try a different photo."
        }
        return "\(Self.kilobytes(photo.jpeg.count)), location and camera details removed. \(Self.estimate(photo.jpeg.count))"
    }

    static func kilobytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// An honest range: Bluetooth LE between phones moves very roughly 5–50 KB a second,
    /// and the encrypted pieces add about a third. Not measured on phones yet.
    static func estimate(_ bytes: Int) -> String {
        let onAir = Double(bytes) * 1.37
        let fast = max(1, Int((onAir / 50_000).rounded(.up)))
        let slow = max(fast + 1, Int((onAir / 5_000).rounded(.up)))
        return "Sending takes roughly \(fast)–\(slow) seconds."
    }
}
