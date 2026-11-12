import CoreTransferable
import EarshotKit
import SwiftUI
import UniformTypeIdentifiers

/// The JPEG of a stored photo, handed to the share sheet as it is (no re-encoding).
/// From the share sheet the person can save it to Photos, AirDrop it, and so on; Earshot
/// itself never asks for access to the photo library.
struct SharedPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .suggestedFileName("Earshot photo.jpg")
    }
}

/// A photo full screen: pinch or double-tap to zoom, drag to look around when zoomed,
/// share (which includes "Save Image"), delete.
struct PhotoViewer: View {
    let message: Message
    let senderName: String
    let onDelete: () -> Void

    @Environment(Messenger.self) private var messenger
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?
    @State private var data: Data?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var confirmingDelete = false

    private var who: String { message.direction == .outgoing ? "you" : senderName.firstName }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoom.simultaneously(with: pan))
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel(accessibilityDescription)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("viewer.image")
                    .accessibilityZoomAction { action in
                        switch action.direction {
                        case .zoomIn: setScale(min(scale + 1, 4))
                        case .zoomOut: setScale(max(scale - 1, 1))
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            if !message.text.isEmpty {
                FormattedText(text: message.text, isOutgoing: true)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.6))
            }
        }
        .statusBarHidden(scale > 1)
        .task {
            guard let source = messenger.photoSource(for: message) else { return }
            switch source {
            case .data(let bytes): data = bytes
            case .file(let url): data = try? Data(contentsOf: url)
            }
            image = await PhotoLoader.shared.load(source, key: message.photo?.fileName ?? "", maxPixelSize: 2048)
        }
        .confirmationDialog("Delete this photo from this phone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete from This Phone", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("\(senderName.firstName)'s copy is not affected.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("viewer.close")
            Spacer()
            if let data {
                ShareLink(item: SharedPhoto(data: data),
                          preview: SharePreview("Photo from \(who)", image: Image(uiImage: image ?? UIImage()))) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share or save")
                .accessibilityIdentifier("viewer.share")
            }
            Button { confirmingDelete = true } label: {
                Image(systemName: "trash").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("viewer.delete")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(.black.opacity(0.35))
    }

    private var accessibilityDescription: String {
        var text = "Photo from \(who)"
        if !message.text.isEmpty { text += ". " + MessageFormatting.plainText(message.text) }
        return text
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 5) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { setScale(1) }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() { setScale(scale > 1 ? 1 : 2.5) }

    private func setScale(_ value: CGFloat) {
        let change = {
            scale = value
            lastScale = value
            if value == 1 { offset = .zero; lastOffset = .zero }
        }
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.25), change) }
    }
}
