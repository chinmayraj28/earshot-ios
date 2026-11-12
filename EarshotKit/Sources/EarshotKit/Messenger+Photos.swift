import CryptoKit
import Foundation
import os

/// A photo that is arriving right now, for drawing a placeholder with a progress bar.
public struct IncomingPhoto: Identifiable, Sendable, Equatable {
    /// The message ID it will have once it is complete.
    public let id: UUID
    /// The sender's hint about the shape, for the placeholder only. 0 when missing or absurd.
    public let width: Int
    public let height: Int
    /// A tiny JPEG for a blurred placeholder. Already checked to be a small, real image.
    public let preview: Data?
    public let byteCount: Int
    public let startedAt: Date
}

/// Why a photo was not delivered, when Earshot knows more than "no receipt came back".
public enum PhotoFailure: Sendable, Equatable {
    /// The other person's Earshot is a version that cannot receive photos.
    case notSupported
    /// Their phone said no: too large, out of photo storage, or the photo failed its checks.
    case refused
    /// The link stopped making progress for too long.
    case stalled
    /// You cancelled it.
    case cancelled
    /// The photo's file is gone from this phone.
    case missingFile
}

/// Sending and receiving photos over an established link.
///
/// How a photo travels (all inside the encrypted channel, see `PhotoWire.swift`):
///
/// 1. The sender checks that the other phone announced `Feature.photo` on this link.
///    If not, nothing photo-related is ever sent to it.
/// 2. `photoStart` describes the file: size, SHA-256, a hint of its shape and a tiny preview.
/// 3. The file follows as `photoPiece`s of 4 KB, in order. The receiver writes each one
///    straight to disk and answers `photoProgress`. The sender keeps at most three pieces
///    unconfirmed, so a text message (sent at once, as always) never waits behind more
///    than about 16 KB of photo.
/// 4. When the last byte is in, the receiver checks the size, the SHA-256 and that the
///    file is a real, sane JPEG, stores it, and only then sends the usual receipt. So
///    "Delivered" on a photo means: fully received, checked and stored.
///
/// If the link drops, the receiver throws away what it has and the sender's photo goes
/// back to "Waiting"; it starts again from the beginning on the next link. One photo is
/// sent per link at a time; others queue behind it.
extension Messenger {
    /// What the sender keeps about a photo it is sending.
    struct OutgoingTransfer {
        let attempt = UUID()
        let messageID: UUID
        let contactID: ContactID
        let token: PeerToken
        let linkID: UUID
        /// The whole JPEG. At most `PhotoLimits.maxPreparedBytes`; read once per attempt.
        let data: Data
        let pieceCount: Int
        /// Index of the next piece to send.
        var nextPiece = 0
        /// Pieces the receiver has confirmed.
        var confirmed = 0
        var lastProgress = ContinuousClock.now
        let startedAt = ContinuousClock.now
    }

    /// What the receiver keeps about a photo it is receiving.
    struct IncomingTransfer {
        let attempt = UUID()
        let messageID: UUID
        let contactID: ContactID
        let token: PeerToken
        let linkID: UUID
        let size: Int
        let sha256: Data
        let caption: String
        let file: IncomingFile
        var hasher = SHA256()
        var received = 0
        var nextIndex = 0
        var lastActivity = ContinuousClock.now
        let startedAt = ContinuousClock.now
        /// True once every byte is in and the image is being checked.
        var isChecking = false
    }

    // MARK: Public API

    /// True when a new photo can be sent to this contact right now: they are connected and
    /// their Earshot announced, on this very link, that it can receive photos.
    public func canSendPhoto(to id: ContactID) -> Bool {
        // Read from the links themselves (not `photoCapableContacts`, which is refreshed a
        // moment later) so this is already true inside the `.connected` event.
        contact(id)?.isBlocked == false
            && links.values.contains { $0.contactID == id && $0.peerFeatures.contains(Feature.photo) }
    }

    /// Sends a prepared photo (see `PhotoProcessing.prepare`) with an optional caption.
    ///
    /// A photo can only be *started* while `canSendPhoto(to:)` is true. Once started it
    /// behaves like a text message: if the link drops it waits, and starts again from the
    /// beginning the next time the two phones are linked.
    @discardableResult
    public func sendPhoto(_ photo: PreparedPhoto, caption: String = "", to id: ContactID) -> Message? {
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendPhoto(to: id), caption.count <= Limits.maxMessageLength,
              !photo.jpeg.isEmpty, photo.jpeg.count <= PhotoLimits.maxPreparedBytes else { return nil }
        let messageID = UUID()
        let name = AttachmentStore.fileName(for: messageID)
        do {
            try attachments.save(photo.jpeg, as: name)
        } catch {
            return nil
        }
        let attachment = PhotoAttachment(fileName: name, byteCount: photo.jpeg.count, width: photo.width, height: photo.height)
        let message = Message(id: messageID, direction: .outgoing, text: caption, status: .waiting, photo: attachment)
        conversations[id, default: Conversation()].messages.append(message)
        knownMessageIDs[id, default: []].insert(messageID)
        transmit(messageID, to: id)
        persist(id)
        return conversations[id]?.messages.first { $0.id == messageID }
    }

    /// Stops sending a photo. It is marked "Not delivered" and can be retried or deleted.
    public func cancelPhoto(_ messageID: UUID, in id: ContactID) {
        guard let message = messages(for: id).first(where: { $0.id == messageID }),
              message.direction == .outgoing, message.photo != nil,
              message.status == .sending || message.status == .waiting else { return }
        failPhoto(messageID, in: id, because: .cancelled)
    }

    /// Where to read a stored photo from: its file on disk, or memory in demo mode and tests.
    public func photoSource(for message: Message) -> PhotoSource? {
        guard let name = message.photo?.fileName else { return nil }
        if let url = attachments.url(named: name) { return .file(url) }
        return attachments.data(named: name).map(PhotoSource.data)
    }

    // MARK: Features

    /// Keeps the announced feature list small and sane; a hostile peer cannot make us store junk.
    static func acceptedFeatures(_ announced: [String]?) -> Set<String> {
        Set((announced ?? []).prefix(32).filter { $0.count <= 64 })
    }

    // MARK: Sending

    func transmitPhoto(_ message: Message, to id: ContactID, over link: Link) {
        guard link.peerFeatures.contains(Feature.photo) else {
            // Their Earshot cannot decode photo payloads: sending one would only close the link.
            setStatus(.failed, of: message.id, in: id)
            photoFailures[message.id] = .notSupported
            persist(id)
            return
        }
        photoFailures[message.id] = nil
        setStatus(.sending, of: message.id, in: id)
        startNextPhoto(on: link.token)
    }

    /// Starts the oldest queued photo for this link, unless one is already on its way.
    private func startNextPhoto(on token: PeerToken) {
        while true {
            guard let link = links[token], let id = link.contactID, link.peerFeatures.contains(Feature.photo),
                  !outgoingTransfers.values.contains(where: { $0.token == token }),
                  let message = messages(for: id).first(where: {
                      $0.direction == .outgoing && $0.photo != nil && $0.status == .sending
                  }) else { return }
            guard let data = photoSource(for: message).flatMap(Self.read), !data.isEmpty,
                  data.count <= PhotoLimits.maxIncomingBytes else {
                setStatus(.failed, of: message.id, in: id)
                photoFailures[message.id] = .missingFile
                persist(id)
                continue
            }
            let start = PhotoStart(id: message.id, size: data.count, sha256: Data(SHA256.hash(data: data)),
                                   width: message.photo?.width ?? 0, height: message.photo?.height ?? 0,
                                   preview: PhotoProcessing.makePreview(from: .data(data)),
                                   caption: message.text.isEmpty ? nil : message.text)
            let pieceCount = (data.count + PhotoLimits.pieceBytes - 1) / PhotoLimits.pieceBytes
            let transfer = OutgoingTransfer(messageID: message.id, contactID: id, token: token, linkID: link.id,
                                            data: data, pieceCount: pieceCount)
            outgoingTransfers[message.id] = transfer
            photoProgress[message.id] = 0
            takeSendAllowance(on: token, force: true)
            do {
                try send(.photoStart(start), to: token)
            } catch {
                linkBroke(token)
                return
            }
            watchOutgoing(message.id, attempt: transfer.attempt)
            sendPieces(message.id)
            return
        }
    }

    private static func read(_ source: PhotoSource) -> Data? {
        switch source {
        case .data(let data): data
        case .file(let url): try? Data(contentsOf: url)
        }
    }

    /// Sends pieces until `PhotoLimits.piecesInFlight` are unconfirmed or the file is done.
    /// State is written back before every send, because on a fast link the answer can
    /// arrive (and change the state) before `send` returns.
    private func sendPieces(_ messageID: UUID) {
        while var transfer = outgoingTransfers[messageID],
              transfer.nextPiece < transfer.pieceCount,
              transfer.nextPiece - transfer.confirmed < PhotoLimits.piecesInFlight {
            let index = transfer.nextPiece
            transfer.nextPiece += 1
            outgoingTransfers[messageID] = transfer
            let lower = index * PhotoLimits.pieceBytes
            let upper = min(lower + PhotoLimits.pieceBytes, transfer.data.count)
            let piece = PhotoPiece(id: messageID, index: index, data: Data(transfer.data[lower..<upper]))
            do {
                try send(.photoPiece(piece), to: transfer.token)
            } catch {
                linkBroke(transfer.token)
                return
            }
        }
    }

    /// The link is gone but we have not been told yet: let the normal path park and resend.
    private func linkBroke(_ token: PeerToken) {
        drop(token, because: .protocolViolation)
        refresh()
    }

    /// Fails the photo if the receiver confirms nothing new for `photoStallTimeout`.
    private func watchOutgoing(_ messageID: UUID, attempt: UUID) {
        after(configuration.photoStallTimeout / 4) { messenger in
            guard let transfer = messenger.outgoingTransfers[messageID], transfer.attempt == attempt else { return }
            if ContinuousClock.now - transfer.lastProgress >= messenger.configuration.photoStallTimeout {
                messenger.failPhoto(messageID, in: transfer.contactID, because: .stalled)
            } else {
                messenger.watchOutgoing(messageID, attempt: attempt)
            }
        }
    }

    private func progressReceived(_ progress: PhotoProgress, from token: PeerToken) throws {
        guard var transfer = outgoingTransfers[progress.id], transfer.token == token else { return }
        guard progress.received > transfer.confirmed, progress.received <= transfer.nextPiece else {
            throw LinkFailure.protocolViolation
        }
        transfer.confirmed = progress.received
        transfer.lastProgress = .now
        outgoingTransfers[progress.id] = transfer
        photoProgress[progress.id] = Double(transfer.confirmed) / Double(transfer.pieceCount)
        sendPieces(progress.id)
    }

    /// A receipt arrived: if it was for a photo on its way, that transfer is finished.
    func photoDelivered(_ messageID: UUID, on token: PeerToken) {
        guard let transfer = outgoingTransfers[messageID], transfer.token == token else { return }
        outgoingTransfers[messageID] = nil
        photoProgress[messageID] = nil
        Self.logThroughput("sent", bytes: transfer.data.count, since: transfer.startedAt)
        startNextPhoto(on: token)
    }

    /// Marks a photo "Not delivered", tells the other phone to throw away what it has,
    /// and moves on to the next queued photo.
    private func failPhoto(_ messageID: UUID, in id: ContactID, because reason: PhotoFailure) {
        let transfer = outgoingTransfers.removeValue(forKey: messageID)
        photoProgress[messageID] = nil
        if let transfer, reason != .refused, links[transfer.token]?.id == transfer.linkID {
            try? send(.photoCancel(messageID), to: transfer.token)
        }
        setStatus(.failed, of: messageID, in: id)
        photoFailures[messageID] = reason
        persist(id)
        if let transfer { startNextPhoto(on: transfer.token) }
    }

    // MARK: Receiving

    func handlePhoto(_ payload: Payload, from token: PeerToken) throws {
        guard let link = links[token], let id = link.contactID else { return }
        switch payload {
        case .photoStart(let start): try photoStarted(start, from: token, link: link, contact: id)
        case .photoPiece(let piece): try pieceReceived(piece, from: token)
        case .photoProgress(let progress): try progressReceived(progress, from: token)
        case .photoCancel(let messageID):
            if let transfer = incomingTransfers[messageID], transfer.token == token, !transfer.isChecking {
                discardIncoming(messageID)
            }
        case .photoRefuse(let messageID):
            if let transfer = outgoingTransfers[messageID], transfer.token == token {
                failPhoto(messageID, in: transfer.contactID, because: .refused)
            }
        default:
            break
        }
    }

    private func photoStarted(_ start: PhotoStart, from token: PeerToken, link: Link, contact id: ContactID) throws {
        // Malformed descriptions are a protocol violation; honest-but-unacceptable ones are refused politely.
        guard start.sha256.count == 32, start.size > 0,
              (start.preview?.count ?? 0) <= PhotoLimits.maxPreviewBytes,
              (start.caption?.count ?? 0) <= Limits.maxMessageLength else { throw LinkFailure.protocolViolation }
        try chargeIncomingMessage(on: token)
        if knownMessageIDs[id]?.contains(start.id) == true {
            // Already stored (an earlier receipt was lost): confirm again, take nothing.
            try send(.ack(start.id), to: token)
            return
        }
        if let existing = incomingTransfers[start.id] {
            guard existing.token != token else { throw LinkFailure.protocolViolation }
            // Fully received over the previous link and being checked right now: once stored,
            // the receipt goes out over this link; the pieces that follow are ignored.
            if existing.isChecking { return }
            discardIncoming(start.id)
        }
        func refuse() throws { try send(.photoRefuse(start.id), to: token) }
        guard start.size <= PhotoLimits.maxIncomingBytes else { return try refuse() }
        let onThisLink = incomingTransfers.values.filter { $0.token == token }.count
        guard onThisLink < PhotoLimits.maxConcurrentIncoming else { return try refuse() }
        let reserved = incomingTransfers.values.reduce(0) { $0 + $1.size }
        guard attachments.usedBytes() + reserved + start.size <= configuration.photoStorageQuota else { return try refuse() }
        guard let file = try? attachments.beginIncoming(as: AttachmentStore.fileName(for: start.id)) else {
            return try refuse()
        }
        let transfer = IncomingTransfer(messageID: start.id, contactID: id, token: token, linkID: link.id,
                                        size: start.size, sha256: start.sha256, caption: start.caption ?? "", file: file)
        incomingTransfers[start.id] = transfer
        // The preview is decoded on screen, so it gets the same "is this a real, small image" check.
        let preview = start.preview.flatMap { data in
            PhotoProcessing.validate(.data(data), maxSide: 64, maxPixels: 64 * 64) != nil ? data : nil
        }
        let sane = (1...20_000).contains(start.width) && (1...20_000).contains(start.height)
        incomingPhotos[id, default: []].append(IncomingPhoto(id: start.id, width: sane ? start.width : 0,
                                                             height: sane ? start.height : 0, preview: preview,
                                                             byteCount: start.size, startedAt: Date()))
        photoProgress[start.id] = 0
        watchIncoming(start.id, attempt: transfer.attempt)
    }

    private func pieceReceived(_ piece: PhotoPiece, from token: PeerToken) throws {
        try chargeIncomingPhotoBytes(piece.data.count, on: token)
        guard !piece.data.isEmpty, piece.data.count <= PhotoLimits.maxIncomingPieceBytes, piece.index >= 0 else {
            throw LinkFailure.protocolViolation
        }
        // Pieces of a photo we refused, cancelled or already have are ignored (they were
        // already charged against the allowance above).
        guard var transfer = incomingTransfers[piece.id], transfer.token == token, !transfer.isChecking else { return }
        guard piece.index == transfer.nextIndex, transfer.received + piece.data.count <= transfer.size else {
            throw LinkFailure.protocolViolation
        }
        do {
            try transfer.file.append(piece.data)
        } catch {
            discardIncoming(piece.id)
            try send(.photoRefuse(piece.id), to: token)
            return
        }
        transfer.hasher.update(data: piece.data)
        transfer.received += piece.data.count
        transfer.nextIndex += 1
        transfer.lastActivity = .now
        incomingTransfers[piece.id] = transfer
        photoProgress[piece.id] = Double(transfer.received) / Double(transfer.size)
        try send(.photoProgress(PhotoProgress(id: piece.id, received: transfer.nextIndex)), to: token)
        if transfer.received == transfer.size { checkIncoming(piece.id) }
    }

    /// Every byte is in. Checks the hash here, then the image itself on a background task
    /// (decoding can take a moment), then stores it as a message.
    private func checkIncoming(_ messageID: UUID) {
        guard var transfer = incomingTransfers[messageID] else { return }
        let digest = Data(transfer.hasher.finalize())
        guard digest == transfer.sha256, (try? transfer.file.close()) != nil else {
            refuseIncoming(messageID)
            return
        }
        transfer.isChecking = true
        incomingTransfers[messageID] = transfer
        let source = transfer.file.source, attempt = transfer.attempt
        Task.detached(priority: .userInitiated) { [weak self] in
            let size = PhotoProcessing.validate(source)
            await self?.incomingChecked(messageID, attempt: attempt, size: size)
        }
    }

    private func incomingChecked(_ messageID: UUID, attempt: UUID, size: (width: Int, height: Int)?) {
        guard let transfer = incomingTransfers[messageID], transfer.attempt == attempt else { return }
        guard let size, let contact = contact(transfer.contactID), !contact.isBlocked,
              knownMessageIDs[transfer.contactID]?.contains(messageID) != true,
              (try? transfer.file.commit()) != nil else {
            refuseIncoming(messageID)
            return
        }
        incomingTransfers[messageID] = nil
        photoProgress[messageID] = nil
        removePlaceholder(messageID, of: transfer.contactID)
        Self.logThroughput("received", bytes: transfer.size, since: transfer.startedAt)
        let attachment = PhotoAttachment(fileName: transfer.file.name, byteCount: transfer.size,
                                         width: size.width, height: size.height)
        let message = Message(id: messageID, direction: .incoming, text: transfer.caption, status: .delivered,
                              photo: attachment)
        storeIncoming(message, from: transfer.contactID, token: transfer.token, linkID: transfer.linkID, orNewerLink: true)
    }

    /// Throws away a photo being received and tells the sender, if the link is still the same.
    private func refuseIncoming(_ messageID: UUID) {
        guard let transfer = incomingTransfers[messageID] else { return }
        discardIncoming(messageID)
        if links[transfer.token]?.id == transfer.linkID { try? send(.photoRefuse(messageID), to: transfer.token) }
    }

    private func discardIncoming(_ messageID: UUID) {
        guard let transfer = incomingTransfers.removeValue(forKey: messageID) else { return }
        transfer.file.discard()
        photoProgress[messageID] = nil
        removePlaceholder(messageID, of: transfer.contactID)
    }

    private func removePlaceholder(_ messageID: UUID, of id: ContactID) {
        incomingPhotos[id]?.removeAll { $0.id == messageID }
        if incomingPhotos[id]?.isEmpty == true { incomingPhotos[id] = nil }
    }

    /// Gives up on a photo whose pieces stopped coming.
    private func watchIncoming(_ messageID: UUID, attempt: UUID) {
        after(configuration.incomingPhotoIdleTimeout / 3) { messenger in
            guard let transfer = messenger.incomingTransfers[messageID], transfer.attempt == attempt,
                  !transfer.isChecking else { return }
            if ContinuousClock.now - transfer.lastActivity >= messenger.configuration.incomingPhotoIdleTimeout {
                messenger.refuseIncoming(messageID)
            } else {
                messenger.watchIncoming(messageID, attempt: attempt)
            }
        }
    }

    /// Enforces the per-link allowance for photo bytes, in the spirit of `chargeIncomingMessage`.
    private func chargeIncomingPhotoBytes(_ count: Int, on token: PeerToken) throws {
        guard var link = links[token] else { return }
        let now = ContinuousClock.now
        let elapsed = now - link.photoBudgetUpdated
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        link.photoByteBudget = min(configuration.incomingPhotoByteBurst,
                                   link.photoByteBudget + seconds * configuration.incomingPhotoByteRate)
        link.photoBudgetUpdated = now
        guard link.photoByteBudget >= Double(count) else { throw LinkFailure.protocolViolation }
        link.photoByteBudget -= Double(count)
        links[token] = link
    }

    // MARK: Cleaning up

    /// A link closed: photos being received over it are thrown away (unless already fully
    /// received and being checked; those are still stored), photos being sent stop. The
    /// sender's message goes back to "Waiting" through the usual path and starts again later.
    func endPhotoTransfers(on token: PeerToken) {
        for (messageID, transfer) in incomingTransfers where transfer.token == token && !transfer.isChecking {
            discardIncoming(messageID)
        }
        for (messageID, transfer) in outgoingTransfers where transfer.token == token {
            outgoingTransfers[messageID] = nil
            photoProgress[messageID] = nil
        }
    }

    /// Everything stops (going off the air, erasing): nothing half-done survives.
    func endAllPhotoTransfers() {
        for messageID in Array(incomingTransfers.keys) { discardIncoming(messageID) }
        for messageID in Array(outgoingTransfers.keys) { photoProgress[messageID] = nil }
        outgoingTransfers.removeAll()
    }

    /// Messages were removed (deleted, conversation cleared, contact removed, history
    /// trimmed): stop sending any of them and delete their files.
    func forgetPhotos(of messages: [Message]) {
        for message in messages {
            guard let photo = message.photo else { continue }
            if let transfer = outgoingTransfers.removeValue(forKey: message.id) {
                photoProgress[message.id] = nil
                if links[transfer.token]?.id == transfer.linkID { try? send(.photoCancel(message.id), to: transfer.token) }
                startNextPhoto(on: transfer.token)
            }
            photoFailures[message.id] = nil
            attachments.delete(named: photo.fileName)
        }
    }

    // MARK: Diagnostics

    private static let photoLog = Logger(subsystem: "app.earshot", category: "photos")
    private static let echoesPhotoLog = ProcessInfo.processInfo.environment["EARSHOT_BT_DEBUG"] != nil

    /// One line per finished transfer: size, time and speed. Never contents, names or IDs.
    /// Visible in Console (debug level) and, with `EARSHOT_BT_DEBUG` set, on standard error.
    private static func logThroughput(_ direction: String, bytes: Int, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let seconds = max(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, 0.001)
        let text = String(format: "photo %@: %d bytes in %.2f s (%.1f KB/s)", direction, bytes, seconds,
                          Double(bytes) / 1024 / seconds)
        photoLog.debug("\(text, privacy: .public)")
        if echoesPhotoLog { FileHandle.standardError.write(Data("[photo] \(text)\n".utf8)) }
    }
}
