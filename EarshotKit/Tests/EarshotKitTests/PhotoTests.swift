import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EarshotKit

// MARK: Helpers

/// A prepared photo, made once: preparing takes a few tens of milliseconds.
@MainActor
enum Samples {
    /// About 1280 × 960, the size a real photo ends up as.
    static let large: PreparedPhoto = try! PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(seed: 1)))
    /// A small one (a few pieces) for tests that only care about the flow.
    static let small: PreparedPhoto = try! PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 320, height: 240, seed: 2)))
}

extension Messenger.Configuration {
    static var photoFast: Messenger.Configuration {
        var c = Messenger.Configuration.fast
        c.photoStallTimeout = .milliseconds(400)
        c.incomingPhotoIdleTimeout = .milliseconds(400)
        return c
    }

    static var legacy: Messenger.Configuration {
        var c = Messenger.Configuration.photoFast
        c.legacyProtocolForTesting = true
        return c
    }
}

@MainActor
func makePhotoPhone(_ hub: LoopbackHub, _ name: String, attachments: AttachmentStore = AttachmentStore(),
                    persistence: InMemoryPersistence = InMemoryPersistence(),
                    identityStore: InMemoryIdentityStore = InMemoryIdentityStore(),
                    configuration: Messenger.Configuration = .photoFast) -> (phone: Phone, attachments: AttachmentStore) {
    let transport = hub.makeTransport(token: name.lowercased() + "-" + UUID().uuidString.prefix(4))
    let messenger = Messenger(transport: transport, persistence: persistence, identityStore: identityStore,
                              attachments: attachments, configuration: configuration)
    messenger.completeOnboarding(displayName: name)
    messenger.start()
    return (Phone(messenger: messenger, transport: transport, persistence: persistence, identityStore: identityStore), attachments)
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A frozen copy of the payload format from before photos existed (commit 38619ad).
/// Decoding with it shows exactly what an older Earshot can and cannot read.
enum LegacyPayload: Codable, Equatable {
    struct Auth: Codable, Equatable { var identityKey: Data; var name: String; var signature: Data }
    struct Text: Codable, Equatable { var id: UUID; var text: String }
    case knock(Data)
    case auth(Auth)
    case text(Text)
    case ack(UUID)
    case bye
}

func photoStart(for data: Data, id: UUID = UUID(), size: Int? = nil, hash: Data? = nil) -> PhotoStart {
    PhotoStart(id: id, size: size ?? data.count, sha256: hash ?? Data(SHA256.hash(data: data)), width: 4, height: 3)
}

/// Splits `data` into protocol pieces.
func pieces(of data: Data, id: UUID, size: Int = PhotoLimits.pieceBytes) -> [PhotoPiece] {
    stride(from: 0, to: data.count, by: size).enumerated().map { index, lower in
        PhotoPiece(id: id, index: index, data: Data(data[lower..<min(lower + size, data.count)]))
    }
}

/// Connects a fresh phone to a raw peer and returns the contact ID the phone sees.
@MainActor
func linkToRawPeer(_ phone: Phone, _ raw: RawPeer) throws -> ContactID {
    phone.messenger.connect(to: try #require(phone.messenger.nearbyPeers.first { $0.id == raw.transport.token }))
    let id = try #require(phone.messenger.contacts.first).id
    #expect(phone.messenger.linkState(for: id) == .connected)
    return id
}

extension RawPeer {
    var refusals: [UUID] { received.compactMap { if case .photoRefuse(let id) = $0 { id } else { nil } } }
    var acks: [UUID] { received.compactMap { if case .ack(let id) = $0 { id } else { nil } } }
}

// MARK: Sending and receiving

@MainActor
@Suite struct PhotoTransferTests {
    @Test func photoIsDeliveredOnlyOnceFullyReceivedCheckedAndStored() async throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, bFiles) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        #expect(a.messenger.canSendPhoto(to: ids.aSeesB) && b.messenger.canSendPhoto(to: ids.bSeesA))

        let photo = Samples.large
        let sent = try #require(a.messenger.sendPhoto(photo, caption: "  The *view* from here  ", to: ids.aSeesB))
        #expect(sent.text == "The *view* from here")
        #expect(sent.photo?.byteCount == photo.jpeg.count)
        await waitUntil("delivered") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }

        let received = try #require(b.messenger.messages(for: ids.bSeesA).last)
        #expect(received.id == sent.id && received.direction == .incoming && received.text == "The *view* from here")
        let attachment = try #require(received.photo)
        #expect(attachment.width == photo.width && attachment.height == photo.height)
        #expect(bFiles.data(named: attachment.fileName) == photo.jpeg)
        #expect(b.messenger.incomingPhotos.isEmpty)
        #expect(a.messenger.photoProgress.isEmpty && b.messenger.photoProgress.isEmpty)
        #expect(a.messenger.outgoingTransfers.isEmpty && b.messenger.incomingTransfers.isEmpty)
        #expect(b.messenger.conversations[ids.bSeesA]?.unreadCount == 1)
    }

    @Test func photosGoBothWaysAndQueueOneAtATime() async throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        let first = try #require(a.messenger.sendPhoto(Samples.small, to: ids.aSeesB))
        let second = try #require(a.messenger.sendPhoto(Samples.small, to: ids.aSeesB))
        let back = try #require(b.messenger.sendPhoto(Samples.small, to: ids.bSeesA))
        await waitUntil("all delivered") {
            a.messenger.messages(for: ids.aSeesB).filter { $0.direction == .outgoing }.allSatisfy { $0.status == .delivered }
                && b.messenger.messages(for: ids.bSeesA).last { $0.direction == .outgoing }?.status == .delivered
        }
        #expect(Set(b.messenger.messages(for: ids.bSeesA).filter { $0.direction == .incoming }.map(\.id)) == [first.id, second.id])
        #expect(a.messenger.messages(for: ids.aSeesB).contains { $0.id == back.id && $0.photo != nil })
    }

    @Test func textAndReceiptsAreNotHeldBehindAPhoto() async throws {
        // Every frame takes a moment, like a real radio, so the photo takes a while.
        let hub = LoopbackHub(latency: .milliseconds(2))
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        await waitUntil("found each other") { !a.messenger.nearbyPeers.isEmpty }
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        await waitUntil("request") { !b.messenger.requests.isEmpty }
        b.messenger.accept(try #require(b.messenger.requests.first))
        await waitUntil("linked") { !a.messenger.photoCapableContacts.isEmpty && !b.messenger.photoCapableContacts.isEmpty }
        let aSeesB = try #require(a.messenger.contacts.first).id
        let bSeesA = try #require(b.messenger.contacts.first).id

        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: aSeesB))
        await waitUntil("photo under way") { (b.messenger.photoProgress[photo.id] ?? 0) > 0 }
        a.messenger.send("Text overtakes the photo", to: aSeesB)
        await waitUntil("text arrives") { b.messenger.messages(for: bSeesA).contains { $0.text == "Text overtakes the photo" } }
        // The text got through, and was confirmed, while the photo was still on its way.
        #expect(!b.messenger.incomingPhotos.isEmpty)
        await waitUntil("text receipt") { a.messenger.messages(for: aSeesB).last?.status == .delivered }
        #expect(a.messenger.messages(for: aSeesB).first { $0.id == photo.id }?.status == .sending)
        await waitUntil("photo delivered", timeout: .seconds(10)) {
            a.messenger.messages(for: aSeesB).first { $0.id == photo.id }?.status == .delivered
        }
    }

    @Test func aSlowButSteadyPhotoDoesNotTimeOut() async throws {
        // The whole transfer takes longer than the stall timeout, but keeps making progress.
        let hub = LoopbackHub(latency: .milliseconds(5))
        var configuration = Messenger.Configuration.photoFast
        configuration.photoStallTimeout = .milliseconds(100)
        let (a, _) = makePhotoPhone(hub, "Alex", configuration: configuration)
        let (b, _) = makePhotoPhone(hub, "Blake", configuration: configuration)
        await waitUntil("found") { !a.messenger.nearbyPeers.isEmpty }
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        await waitUntil("request") { !b.messenger.requests.isEmpty }
        b.messenger.accept(try #require(b.messenger.requests.first))
        await waitUntil("linked") { !a.messenger.photoCapableContacts.isEmpty && !b.messenger.photoCapableContacts.isEmpty }
        let id = try #require(a.messenger.contacts.first).id
        let start = ContinuousClock.now
        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: id))
        await waitUntil("delivered", timeout: .seconds(15)) {
            a.messenger.messages(for: id).first { $0.id == photo.id }?.status == .delivered
        }
        #expect(ContinuousClock.now - start > .milliseconds(100), "took longer than the stall timeout, and still succeeded")
    }

    @Test func aStalledPhotoFailsAndCanBeRetried() async throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        // Blake's answers stop arriving, but the link itself stays up.
        hub.intercept = { data, from, _ in from == b.token ? nil : data }
        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: ids.aSeesB))
        await waitUntil("marked not delivered") { a.messenger.messages(for: ids.aSeesB).last?.status == .failed }
        #expect(a.messenger.photoFailures[photo.id] == .stalled)
        // Blake's phone threw its partial copy away (cancel, or its own idle timeout).
        await waitUntil("receiver discarded") { b.messenger.incomingPhotos.isEmpty && b.messenger.incomingTransfers.isEmpty }

        hub.intercept = nil
        a.messenger.retry(photo.id, in: ids.aSeesB)
        await waitUntil("delivered on retry") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).filter { $0.id == photo.id }.count == 1)
    }

    @Test func droppedLinkSendsThePhotoBackToWaitingAndRestartsOnReconnect() async throws {
        let hub = LoopbackHub()
        let directory = temporaryDirectory()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, bFiles) = makePhotoPhone(hub, "Blake", attachments: AttachmentStore(directory: directory))
        let ids = try befriend(a, b)

        // Let a few pieces through, then the radio goes quiet and the link drops.
        var piecesSeen = 0
        hub.intercept = { data, from, _ in
            guard from == a.token else { return data }
            piecesSeen += 1
            return piecesSeen <= 5 ? data : nil
        }
        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: ids.aSeesB))
        #expect(b.messenger.incomingPhotos[ids.bSeesA]?.count == 1)
        #expect(bFiles.allNames().contains { $0.hasSuffix(".partial") })
        hub.setReachable(false, b.transport)

        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .waiting)
        #expect(a.messenger.photoProgress[photo.id] == nil)
        #expect(b.messenger.incomingPhotos.isEmpty)
        #expect(bFiles.allNames().isEmpty, "the receiver discards partial data")

        hub.intercept = nil
        hub.setReachable(true, b.transport)
        await waitUntil("delivered after reconnecting") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
        #expect(b.messenger.messages(for: ids.bSeesA).filter { $0.id == photo.id }.count == 1)
        #expect(bFiles.allNames() == [AttachmentStore.fileName(for: photo.id)])
    }

    @Test func cancellingStopsTheTransferOnBothPhones() async throws {
        let hub = LoopbackHub(latency: .milliseconds(2))
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, bFiles) = makePhotoPhone(hub, "Blake")
        await waitUntil("found") { !a.messenger.nearbyPeers.isEmpty }
        a.messenger.connect(to: try #require(a.messenger.nearbyPeers.first))
        await waitUntil("request") { !b.messenger.requests.isEmpty }
        b.messenger.accept(try #require(b.messenger.requests.first))
        await waitUntil("linked") { !a.messenger.photoCapableContacts.isEmpty && !b.messenger.photoCapableContacts.isEmpty }
        let id = try #require(a.messenger.contacts.first).id
        let bSeesA = try #require(b.messenger.contacts.first).id

        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: id))
        await waitUntil("under way") { (b.messenger.photoProgress[photo.id] ?? 0) > 0 }
        a.messenger.cancelPhoto(photo.id, in: id)
        #expect(a.messenger.messages(for: id).last?.status == .failed)
        #expect(a.messenger.photoFailures[photo.id] == .cancelled)
        await waitUntil("receiver threw it away") { b.messenger.incomingPhotos.isEmpty }
        await pause(200)
        #expect(b.messenger.messages(for: bSeesA).isEmpty)
        #expect(bFiles.allNames().isEmpty)
        #expect(a.messenger.linkState(for: id) == .connected, "cancelling is not a protocol error")
    }

    @Test func photoCanOnlyBeStartedWhileConnected() throws {
        let hub = LoopbackHub()
        let (a, aFiles) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        hub.setReachable(false, b.transport)
        #expect(!a.messenger.canSendPhoto(to: ids.aSeesB))
        #expect(a.messenger.sendPhoto(Samples.small, to: ids.aSeesB) == nil)
        #expect(a.messenger.messages(for: ids.aSeesB).isEmpty)
        #expect(aFiles.allNames().isEmpty)
    }
}

// MARK: Compatibility with older Earshot

@MainActor
@Suite struct PhotoCompatibilityTests {
    @Test func newAuthDecodesOnAnOldPhoneAndOldAuthDecodesHere() throws {
        let new = Payload.auth(.init(identityKey: Data(repeating: 1, count: 32), name: "Alex",
                                     signature: Data(repeating: 2, count: 64), features: Feature.all))
        let decodedByOld = try JSONDecoder().decode(LegacyPayload.self, from: new.encoded())
        guard case .auth(let auth) = decodedByOld else { Issue.record("not an auth"); return }
        #expect(auth.name == "Alex" && auth.identityKey == Data(repeating: 1, count: 32))

        let old = try JSONEncoder().encode(LegacyPayload.auth(.init(identityKey: Data([1]), name: "Old", signature: Data([2]))))
        guard case .auth(let decoded) = try Payload.decode(old) else { Issue.record("not an auth"); return }
        #expect(decoded.features == nil)
        #expect(Messenger.acceptedFeatures(decoded.features).isEmpty)
    }

    @Test func anOldPhoneCannotDecodeAnyPhotoPayload() throws {
        let id = UUID()
        let payloads: [Payload] = [.photoStart(photoStart(for: Data([1, 2, 3]), id: id)),
                                   .photoPiece(PhotoPiece(id: id, index: 0, data: Data([1]))),
                                   .photoProgress(PhotoProgress(id: id, received: 1)),
                                   .photoCancel(id), .photoRefuse(id)]
        for payload in payloads {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LegacyPayload.self, from: payload.encoded()) }
        }
    }

    /// Both roles: the new phone asks the old one, and the old one asks the new one.
    @Test(arguments: [true, false])
    func newAndOldPhonesConnectAndTextButNoPhotoIsEverSent(newPhoneAsks: Bool) async throws {
        let hub = LoopbackHub()
        let (new, _) = makePhotoPhone(hub, "New")
        let (old, oldFiles) = makePhotoPhone(hub, "Old", configuration: .legacy)
        let ids: (aSeesB: ContactID, bSeesA: ContactID)
        if newPhoneAsks {
            ids = try befriend(new, old)
        } else {
            let reversed = try befriend(old, new)
            ids = (aSeesB: reversed.bSeesA, bSeesA: reversed.aSeesB)
        }

        #expect(!new.messenger.canSendPhoto(to: ids.aSeesB))
        #expect(new.messenger.sendPhoto(Samples.small, to: ids.aSeesB) == nil)
        new.messenger.send("hello old friend", to: ids.aSeesB)
        old.messenger.send("hello new friend", to: ids.bSeesA)
        #expect(new.messenger.messages(for: ids.aSeesB).first?.status == .delivered)
        #expect(old.messenger.messages(for: ids.bSeesA).last?.status == .delivered)
        // An old phone that received a photo payload would have closed the link.
        #expect(new.messenger.linkState(for: ids.aSeesB) == .connected)
        #expect(oldFiles.allNames().isEmpty)

        // Reconnecting goes through the knock path; capabilities are re-learned, still none.
        hub.dropConnection(new.transport, old.transport)
        await waitUntil("reconnected") { new.messenger.linkState(for: ids.aSeesB) == .connected
            && old.messenger.linkState(for: ids.bSeesA) == .connected }
        #expect(!new.messenger.canSendPhoto(to: ids.aSeesB))
        new.messenger.send("still here", to: ids.aSeesB)
        #expect(new.messenger.messages(for: ids.aSeesB).last?.status == .delivered)
    }

    @Test func capabilitiesAreLearnedAgainOnEveryReconnection() async throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        hub.dropConnection(a.transport, b.transport)
        #expect(!a.messenger.canSendPhoto(to: ids.aSeesB))
        await waitUntil("reconnected with knocks") { a.messenger.canSendPhoto(to: ids.aSeesB) && b.messenger.canSendPhoto(to: ids.bSeesA) }
        _ = try #require(a.messenger.sendPhoto(Samples.small, to: ids.aSeesB))
        await waitUntil("delivered") { a.messenger.messages(for: ids.aSeesB).last?.status == .delivered }
    }

    @Test func aWaitingPhotoIsNeverSentToAContactWhoseEarshotNoLongerSupportsPhotos() async throws {
        let hub = LoopbackHub()
        let bPersistence = InMemoryPersistence(), bKeys = InMemoryIdentityStore()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake", persistence: bPersistence, identityStore: bKeys)
        let ids = try befriend(a, b)

        // The photo starts, then the link drops before it is done.
        hub.intercept = { data, from, _ in from == a.token ? nil : data }
        let photo = try #require(a.messenger.sendPhoto(Samples.small, to: ids.aSeesB))
        hub.setReachable(false, b.transport)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .waiting)
        hub.intercept = nil

        // Blake comes back running an older Earshot (same identity and data).
        b.messenger.stop()
        let (oldB, _) = makePhotoPhone(hub, "Blake", persistence: bPersistence, identityStore: bKeys, configuration: .legacy)
        await waitUntil("reconnected") { a.messenger.linkState(for: ids.aSeesB) == .connected }
        await waitUntil("photo marked not delivered") { a.messenger.messages(for: ids.aSeesB).last?.status == .failed }
        #expect(a.messenger.photoFailures[photo.id] == .notSupported)
        a.messenger.send("text still works", to: ids.aSeesB)
        #expect(a.messenger.messages(for: ids.aSeesB).last?.status == .delivered)
        #expect(a.messenger.linkState(for: ids.aSeesB) == .connected, "the old phone never had to drop the link")
        _ = oldB
    }
}

// MARK: Hostile peers

@MainActor
@Suite struct PhotoAdversaryTests {
    @Test func oversizedPhotoIsRefusedBeforeAnythingIsAllocated() throws {
        let hub = LoopbackHub()
        let (a, files) = makePhotoPhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        let id = try linkToRawPeer(a, raw)
        let start = photoStart(for: Data([1]), size: PhotoLimits.maxIncomingBytes + 1)
        try raw.send(.photoStart(start), to: a.token)
        #expect(raw.refusals == [start.id])
        #expect(files.allNames().isEmpty && a.messenger.incomingPhotos.isEmpty)
        #expect(a.messenger.linkState(for: id) == .connected)
    }

    @Test func malformedDescriptionsCloseTheLink() throws {
        for bad in [PhotoStart(id: UUID(), size: 10, sha256: Data(count: 5), width: 1, height: 1),
                    PhotoStart(id: UUID(), size: 0, sha256: Data(count: 32), width: 1, height: 1),
                    PhotoStart(id: UUID(), size: -5, sha256: Data(count: 32), width: 1, height: 1),
                    PhotoStart(id: UUID(), size: 10, sha256: Data(count: 32), width: 1, height: 1,
                               preview: Data(count: PhotoLimits.maxPreviewBytes + 1)),
                    PhotoStart(id: UUID(), size: 10, sha256: Data(count: 32), width: 1, height: 1,
                               caption: String(repeating: "x", count: Limits.maxMessageLength + 1))] {
            let hub = LoopbackHub()
            let (a, _) = makePhotoPhone(hub, "Alex")
            let raw = RawPeer(hub, name: "Raw")
            let id = try linkToRawPeer(a, raw)
            try raw.send(.photoStart(bad), to: a.token)
            #expect(a.messenger.linkState(for: id) != .connected)
        }
    }

    @Test func piecesOutOfOrderTooLargeOrBeyondTheAnnouncedSizeCloseTheLink() throws {
        let data = Samples.small.jpeg
        let cases: [(String, (UUID) -> [PhotoPiece])] = [
            ("skipped a piece", { id in [pieces(of: data, id: id)[1]] }),
            ("repeated a piece", { id in let p = pieces(of: data, id: id); return [p[0], p[0]] }),
            ("piece too large", { id in [PhotoPiece(id: id, index: 0, data: Data(count: PhotoLimits.maxIncomingPieceBytes + 1))] }),
            ("empty piece", { id in [PhotoPiece(id: id, index: 0, data: Data())] }),
            ("more bytes than announced", { id in pieces(of: data + Data(count: 10), id: id) }),
        ]
        for (name, makePieces) in cases {
            let hub = LoopbackHub()
            let (a, files) = makePhotoPhone(hub, "Alex")
            let raw = RawPeer(hub, name: "Raw")
            let contact = try linkToRawPeer(a, raw)
            let start = photoStart(for: data)
            try raw.send(.photoStart(start), to: a.token)
            for piece in makePieces(start.id) { try? raw.send(.photoPiece(piece), to: a.token) }
            #expect(a.messenger.linkState(for: contact) != .connected, "\(name)")
            #expect(a.messenger.incomingPhotos.isEmpty && files.allNames().isEmpty, "\(name)")
            #expect(a.messenger.messages(for: contact).isEmpty, "\(name)")
        }
    }

    @Test func onlyTwoPhotosMayArriveAtOncePerLink() throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        let id = try linkToRawPeer(a, raw)
        let starts = (0..<3).map { _ in photoStart(for: Samples.small.jpeg) }
        for start in starts { try raw.send(.photoStart(start), to: a.token) }
        #expect(raw.refusals == [starts[2].id])
        #expect(a.messenger.incomingPhotos[id]?.count == 2)
    }

    @Test func storageQuotaIsEnforced() throws {
        let hub = LoopbackHub()
        var configuration = Messenger.Configuration.photoFast
        configuration.photoStorageQuota = 50_000
        let files = AttachmentStore()
        let (a, _) = makePhotoPhone(hub, "Alex", attachments: files, configuration: configuration)
        try files.save(Data(count: 45_000), as: AttachmentStore.fileName(for: UUID()))
        let raw = RawPeer(hub, name: "Raw")
        _ = try linkToRawPeer(a, raw)
        let start = photoStart(for: Data(count: 10_000))
        try raw.send(.photoStart(start), to: a.token)
        #expect(raw.refusals == [start.id])
    }

    @Test(arguments: ["wrong hash", "not an image", "PNG instead of JPEG", "decompression bomb", "truncated JPEG"])
    func photosThatFailTheirChecksAreRefusedAndNothingIsStored(kind: String) async throws {
        let hub = LoopbackHub()
        let directory = temporaryDirectory()
        let (a, files) = makePhotoPhone(hub, "Alex", attachments: AttachmentStore(directory: directory))
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)

        var data = Samples.small.jpeg
        var hash: Data?
        switch kind {
        case "wrong hash": hash = Data(SHA256.hash(data: Data("something else".utf8)))
        case "not an image": data = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        case "PNG instead of JPEG": data = PhotoTestImages.png(width: 64, height: 64)
        case "decompression bomb": data = PhotoTestImages.claimingSize(width: 30_000, height: 30_000)
        default: data = Data(data.prefix(data.count / 2))
        }
        let start = photoStart(for: data, hash: hash)
        try raw.send(.photoStart(start), to: a.token)
        for piece in pieces(of: data, id: start.id) { try raw.send(.photoPiece(piece), to: a.token) }
        await waitUntil("refused") { raw.refusals == [start.id] }
        #expect(a.messenger.messages(for: contact).isEmpty)
        #expect(!raw.acks.contains(start.id))
        #expect(files.allNames().isEmpty)
        #expect(a.messenger.incomingPhotos.isEmpty)
        #expect(a.messenger.linkState(for: contact) == .connected)
    }

    @Test func aRealPhotoFromARawPeerIsAcceptedAndConfirmed() async throws {
        let hub = LoopbackHub()
        let (a, files) = makePhotoPhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)
        let data = Samples.small.jpeg
        let start = photoStart(for: data)
        try raw.send(.photoStart(start), to: a.token)
        for piece in pieces(of: data, id: start.id) { try raw.send(.photoPiece(piece), to: a.token) }
        await waitUntil("confirmed") { raw.acks == [start.id] }
        let message = try #require(a.messenger.messages(for: contact).last)
        #expect(message.photo?.width == Samples.small.width, "the size comes from the file, not the claim (4 × 3)")
        #expect(files.data(named: AttachmentStore.fileName(for: start.id)) == data)
        // Sending it again (the receipt was "lost") is confirmed without storing a copy.
        try raw.send(.photoStart(start), to: a.token)
        #expect(raw.acks == [start.id, start.id])
        #expect(a.messenger.messages(for: contact).count == 1)
    }

    @Test func aFloodOfPhotoBytesClosesTheLink() throws {
        let hub = LoopbackHub()
        var configuration = Messenger.Configuration.photoFast
        configuration.incomingPhotoByteBurst = 64 * 1024
        configuration.incomingPhotoByteRate = 1024
        let (a, _) = makePhotoPhone(hub, "Alex", configuration: configuration)
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)
        // Pieces for a photo nobody announced: ignored, but still charged.
        for index in 0..<40 {
            try? raw.send(.photoPiece(PhotoPiece(id: UUID(), index: index, data: Data(count: 4096))), to: a.token)
        }
        #expect(a.messenger.linkState(for: contact) != .connected)
    }

    @Test func aFloodOfPhotoAnnouncementsClosesTheLink() throws {
        let hub = LoopbackHub()
        var configuration = Messenger.Configuration.photoFast
        configuration.incomingBurst = 10
        configuration.incomingRate = 1
        let (a, _) = makePhotoPhone(hub, "Alex", configuration: configuration)
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)
        for _ in 0..<30 { try? raw.send(.photoStart(photoStart(for: Data(count: 100))), to: a.token) }
        #expect(a.messenger.linkState(for: contact) != .connected)
    }

    @Test func blockingMidTransferStopsItAndKeepsNothing() async throws {
        let hub = LoopbackHub()
        let (a, files) = makePhotoPhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)
        let data = Samples.small.jpeg
        let start = photoStart(for: data)
        try raw.send(.photoStart(start), to: a.token)
        let all = pieces(of: data, id: start.id)
        try raw.send(.photoPiece(all[0]), to: a.token)
        a.messenger.setBlocked(true, for: contact)
        #expect(a.messenger.linkState(for: contact) != .connected)
        #expect(a.messenger.incomingPhotos.isEmpty && files.allNames().isEmpty)
        for piece in all.dropFirst() { try? raw.send(.photoPiece(piece), to: a.token) }
        await pause(100)
        #expect(a.messenger.messages(for: contact).isEmpty)
    }

    @Test func strayProgressCancelAndRefusalsAreHarmless() throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let raw = RawPeer(hub, name: "Raw")
        let contact = try linkToRawPeer(a, raw)
        try raw.send(.photoProgress(PhotoProgress(id: UUID(), received: 3)), to: a.token)
        try raw.send(.photoCancel(UUID()), to: a.token)
        try raw.send(.photoRefuse(UUID()), to: a.token)
        #expect(a.messenger.linkState(for: contact) == .connected)
    }

    @Test func progressBeyondWhatWasSentClosesTheLink() async throws {
        let hub = LoopbackHub()
        let (a, _) = makePhotoPhone(hub, "Alex")
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        // Hold Blake's own answers back and forge one claiming far more than was sent.
        hub.intercept = { data, from, _ in from == b.token ? nil : data }
        let photo = try #require(a.messenger.sendPhoto(Samples.large, to: ids.aSeesB))
        hub.intercept = nil
        let forged = PhotoProgress(id: photo.id, received: 999)
        // Sent through Blake's real channel so it decrypts correctly on Alex's phone.
        try b.messenger.send(.photoProgress(forged), to: a.token)
        #expect(a.messenger.linkState(for: ids.aSeesB) != .connected)
    }
}

// MARK: Storage

@MainActor
@Suite struct PhotoStorageTests {
    /// A conversation with one received photo on disk.
    func phoneWithStoredPhoto() async throws -> (a: Phone, b: Phone, files: AttachmentStore, directory: URL,
                                                 ids: (aSeesB: ContactID, bSeesA: ContactID), photo: Message) {
        let hub = LoopbackHub()
        let directory = temporaryDirectory()
        let files = AttachmentStore(directory: directory)
        let (a, _) = makePhotoPhone(hub, "Alex", attachments: files)
        let (b, _) = makePhotoPhone(hub, "Blake")
        let ids = try befriend(a, b)
        let photo = try #require(b.messenger.sendPhoto(Samples.small, to: ids.bSeesA))
        await waitUntil("delivered") { b.messenger.messages(for: ids.bSeesA).last?.status == .delivered }
        a.messenger.send("nice", to: ids.aSeesB)
        #expect(files.allNames() == [AttachmentStore.fileName(for: photo.id)])
        return (a, b, files, directory, ids, photo)
    }

    @Test func filesAreKeptOutOfBackups() async throws {
        let setup = try await phoneWithStoredPhoto()
        let values = try setup.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func deletingAPhotoMessageDeletesItsFile() async throws {
        let s = try await phoneWithStoredPhoto()
        s.a.messenger.deleteMessage(s.photo.id, in: s.ids.aSeesB)
        #expect(s.files.allNames().isEmpty)
        #expect(s.a.messenger.messages(for: s.ids.aSeesB).map(\.text) == ["nice"])
    }

    @Test func clearingAConversationDeletesItsFiles() async throws {
        let s = try await phoneWithStoredPhoto()
        s.a.messenger.clearConversation(s.ids.aSeesB)
        #expect(s.files.allNames().isEmpty)
    }

    @Test func removingAContactDeletesTheirFiles() async throws {
        let s = try await phoneWithStoredPhoto()
        s.a.messenger.removeContact(s.ids.aSeesB)
        #expect(s.files.allNames().isEmpty)
    }

    @Test func erasingEverythingDeletesAllFiles() async throws {
        let s = try await phoneWithStoredPhoto()
        s.a.messenger.eraseEverything()
        #expect(!FileManager.default.fileExists(atPath: s.directory.path) || s.files.allNames().isEmpty)
    }

    @Test func historyTrimmingDeletesTheFilesOfDroppedMessages() throws {
        let hub = LoopbackHub()
        let files = AttachmentStore(directory: temporaryDirectory())
        let me = Identity(), friend = Identity()
        let contact = Contact(id: friend.contactID, displayName: "Jensen", identityKey: friend.publicKey)
        let oldPhoto = UUID()
        let name = AttachmentStore.fileName(for: oldPhoto)
        try files.save(Samples.small.jpeg, as: name)
        var messages = [Message(id: oldPhoto, direction: .incoming, text: "", status: .delivered,
                                photo: PhotoAttachment(fileName: name, byteCount: Samples.small.jpeg.count, width: 1, height: 1))]
        messages += (1..<Limits.maxStoredMessages).map { Message(direction: .incoming, text: "\($0)", status: .delivered) }
        let state = PersistedState(profile: Profile(displayName: "Alex", hasCompletedOnboarding: true),
                                   contacts: [contact], conversations: [contact.id: Conversation(messages: messages)])
        let messenger = Messenger(transport: hub.makeTransport(), persistence: InMemoryPersistence(state),
                                  identityStore: InMemoryIdentityStore(me.rawRepresentation), attachments: files,
                                  configuration: .photoFast)
        #expect(files.allNames() == [name])
        messenger.send("one more", to: contact.id)
        #expect(messenger.messages(for: contact.id).count == Limits.maxStoredMessages)
        #expect(files.allNames().isEmpty)
    }

    @Test func leftoversFromACrashAreDeletedAtLaunch() throws {
        let directory = temporaryDirectory()
        let files = AttachmentStore(directory: directory)
        let friend = Identity()
        let contact = Contact(id: friend.contactID, displayName: "Jensen", identityKey: friend.publicKey)
        let kept = UUID(), orphan = UUID(), halfReceived = UUID()
        try files.save(Data([1]), as: AttachmentStore.fileName(for: kept))
        try files.save(Data([2]), as: AttachmentStore.fileName(for: orphan))
        try Data([3]).write(to: directory.appendingPathComponent(AttachmentStore.fileName(for: halfReceived) + ".partial"))
        let photo = PhotoAttachment(fileName: AttachmentStore.fileName(for: kept), byteCount: 1, width: 1, height: 1)
        let state = PersistedState(profile: Profile(displayName: "Alex", hasCompletedOnboarding: true), contacts: [contact],
                                   conversations: [contact.id: Conversation(messages: [
                                       Message(id: kept, direction: .incoming, text: "", status: .delivered, photo: photo)])])
        _ = Messenger(transport: LoopbackHub().makeTransport(), persistence: InMemoryPersistence(state),
                      identityStore: InMemoryIdentityStore(), attachments: files)
        #expect(files.allNames() == [AttachmentStore.fileName(for: kept)])
    }

    @Test func attachmentNamesCannotEscapeTheFolder() {
        for bad in ["../x.jpg", "/etc/passwd", "a/b.jpg", "x.png", "..jpg", String(repeating: "a", count: 80) + ".jpg"] {
            #expect(!AttachmentStore.isValidName(bad), "\(bad)")
        }
        #expect(AttachmentStore.isValidName(AttachmentStore.fileName(for: UUID())))
    }

    /// Conversations saved by the version before photos (generated with commit 38619ad's
    /// `FilePersistence`, byte for byte) still load, and gain photos afterwards.
    @Test func conversationsSavedBeforePhotosStillLoad() throws {
        let directory = temporaryDirectory()
        let conversations = directory.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try Data(#"{"isVisible":true,"hasCompletedOnboarding":true,"displayName":"Alex"}"#.utf8)
            .write(to: directory.appendingPathComponent("profile.json"))
        try Data(#"[{"isBlocked":false,"identityKey":"6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=","displayName":"Jensen Huang","id":{"rawValue":"fe812c12f3ab4ce6ac5db69ac352f906"},"isVerified":true,"addedAt":784000000}]"#.utf8)
            .write(to: directory.appendingPathComponent("contacts.json"))
        try Data(#"{"unreadCount":1,"messages":[{"status":"delivered","text":"Carriage 2. *They* say twenty minutes.","direction":"incoming","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":784000100.25},{"direction":"outgoing","text":"On my way 🚆","id":"0E984725-C51C-4BF4-9960-E1C80E27ABA0","timestamp":784000200.5,"status":"waiting"}]}"#.utf8)
            .write(to: conversations.appendingPathComponent("fe812c12f3ab4ce6ac5db69ac352f906.json"))

        let store = FilePersistence(directory: directory)
        let state = store.load()
        let contact = try #require(state.contacts.first)
        #expect(contact.displayName == "Jensen Huang" && contact.isVerified)
        let messages = try #require(state.conversations[contact.id]?.messages)
        #expect(messages.map(\.text) == ["Carriage 2. *They* say twenty minutes.", "On my way 🚆"])
        #expect(messages.map(\.status) == [.delivered, .waiting])
        #expect(messages.allSatisfy { $0.photo == nil })
        #expect(state.conversations[contact.id]?.unreadCount == 1)
        #expect(!FileManager.default.fileExists(atPath: conversations.appendingPathComponent("fe812c12f3ab4ce6ac5db69ac352f906.json.unreadable").path))

        // Saving a photo message and loading again keeps it.
        var conversation = try #require(state.conversations[contact.id])
        let photo = PhotoAttachment(fileName: AttachmentStore.fileName(for: UUID()), byteCount: 12, width: 1280, height: 960)
        conversation.messages.append(Message(direction: .incoming, text: "", status: .delivered, photo: photo))
        store.save(conversation: conversation, for: contact.id, completion: nil)
        store.flush()
        #expect(FilePersistence(directory: directory).load().conversations[contact.id]?.messages.last?.photo == photo)
    }
}

// MARK: Preparing and checking images

enum PhotoTestImages {
    static func png(width: Int, height: Int) -> Data {
        let image = PhotoProcessing.sampleImage(width: width, height: height, seed: 0)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A small valid JPEG whose header is edited to claim a huge size.
    static func claimingSize(width: Int, height: Int) -> Data {
        var bytes = [UInt8](PhotoProcessing.sampleJPEG(width: 64, height: 64))
        for index in 0..<(bytes.count - 9) where bytes[index] == 0xFF && (bytes[index + 1] == 0xC0 || bytes[index + 1] == 0xC2) {
            bytes[index + 5] = UInt8(height >> 8); bytes[index + 6] = UInt8(height & 0xFF)
            bytes[index + 7] = UInt8(width >> 8); bytes[index + 8] = UInt8(width & 0xFF)
            break
        }
        return Data(bytes)
    }

    /// Random-looking pixels compress badly: the hardest case for the size target.
    static func noise(width: Int, height: Int) -> Data {
        var state: UInt32 = 12345
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in pixels.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

@Suite struct PhotoProcessingTests {
    static var metadata: [CFString: Any] { [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:12 09:41:00",
                                         kCGImagePropertyExifUserComment: "secret note"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "London"],
    ] }

    @Test func preparedPhotosAreSmallUprightJPEGs() throws {
        let prepared = try PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 4032, height: 3024, seed: 3)))
        #expect(max(prepared.width, prepared.height) == PhotoLimits.maxLongSide)
        #expect(prepared.width == 1280 && prepared.height == 960)
        #expect(prepared.jpeg.count <= PhotoLimits.targetBytes)
        #expect(PhotoProcessing.validate(.data(prepared.jpeg))! == (1280, 960))
        let preview = try #require(prepared.preview)
        #expect(preview.count <= PhotoLimits.maxPreviewBytes)
        #expect(PhotoProcessing.validate(.data(preview), maxSide: 64, maxPixels: 4096) != nil)
    }

    @Test func smallPhotosAreNotScaledUp() throws {
        let prepared = try PhotoProcessing.prepare(.data(PhotoProcessing.sampleJPEG(width: 300, height: 500)))
        #expect(prepared.width == 300 && prepared.height == 500)
    }

    @Test func everyKindOfMetadataIsRemoved() throws {
        let original = PhotoProcessing.sampleJPEG(width: 2000, height: 1500, metadata: Self.metadata)
        // The test input really carries the metadata…
        let before = PhotoTestImages.properties(original)
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        #expect((before[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "iPhone 17 Pro")
        #expect(original.range(of: Data("Exif\0\0".utf8)) != nil)

        // …and the prepared photo has none of it.
        let prepared = try PhotoProcessing.prepare(.data(original))
        let after = PhotoTestImages.properties(prepared.jpeg)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        #expect(after[kCGImagePropertyTIFFDictionary] == nil)
        #expect(after[kCGImagePropertyIPTCDictionary] == nil)
        #expect((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil)
        for marker in ["Exif\0\0", "iPhone", "Apple", "London", "secret note", "2026:11:12", "http://ns.adobe.com/xap", "ICC_PROFILE"] {
            #expect(prepared.jpeg.range(of: Data(marker.utf8)) == nil, "found \(marker)")
        }
        #expect(Self.segmentMarkers(prepared.jpeg).allSatisfy { !(0xE1...0xEF).contains($0) && $0 != 0xFE })
        for data in [prepared.preview].compactMap({ $0 }) {
            #expect(PhotoTestImages.properties(data)[kCGImagePropertyGPSDictionary] == nil)
            #expect(data.range(of: Data("Exif\0\0".utf8)) == nil)
        }
    }

    @Test func cameraRotationIsAppliedToThePixels() throws {
        // Orientation 6: "turn 90° clockwise to view". A landscape sensor image shown as portrait.
        let rotated = PhotoProcessing.sampleJPEG(width: 1600, height: 1200, metadata: [kCGImagePropertyOrientation: 6])
        let prepared = try PhotoProcessing.prepare(.data(rotated))
        #expect(prepared.width == 960 && prepared.height == 1280)
        #expect(PhotoTestImages.properties(prepared.jpeg)[kCGImagePropertyOrientation] == nil)
    }

    @Test func hardToCompressPhotosStillFitTheCap() throws {
        let prepared = try PhotoProcessing.prepare(.data(PhotoTestImages.noise(width: 2400, height: 1800)))
        #expect(prepared.jpeg.count <= PhotoLimits.maxPreparedBytes)
        #expect(max(prepared.width, prepared.height) <= PhotoLimits.maxLongSide)
    }

    @Test func pngAndOtherFormatsCanBePrepared() throws {
        let prepared = try PhotoProcessing.prepare(.data(PhotoTestImages.png(width: 800, height: 600)))
        #expect(prepared.width == 800)
        #expect(PhotoProcessing.validate(.data(prepared.jpeg)) != nil)
    }

    @Test func garbageIsNotAPhoto() {
        #expect(throws: PhotoProcessing.Failure.unreadable) { try PhotoProcessing.prepare(.data(Data("hello".utf8))) }
        #expect(PhotoProcessing.validate(.data(Data())) == nil)
        #expect(PhotoProcessing.validate(.data(Data(repeating: 0xFF, count: 5000))) == nil)
        #expect(PhotoProcessing.stripMetadata(Data([0xFF, 0xD8, 0x00])) == nil)
        #expect(PhotoProcessing.stripMetadata(Data("not a jpeg".utf8)) == nil)
    }

    @Test func receivedImagesAreCheckedBeforeDecoding() {
        #expect(PhotoProcessing.validate(.data(PhotoTestImages.claimingSize(width: 30_000, height: 30_000))) == nil)
        #expect(PhotoProcessing.validate(.data(PhotoTestImages.claimingSize(width: 5000, height: 10))) == nil)
        #expect(PhotoProcessing.validate(.data(PhotoTestImages.png(width: 64, height: 64))) == nil, "only JPEG is accepted")
        let jpeg = PhotoProcessing.sampleJPEG(width: 200, height: 100)
        #expect(PhotoProcessing.validate(.data(Data(jpeg.prefix(jpeg.count / 2)))) == nil, "truncated")
        #expect(PhotoProcessing.validate(.data(jpeg))! == (200, 100))
        #expect(PhotoProcessing.decode(.data(PhotoTestImages.claimingSize(width: 30_000, height: 30_000)), maxPixelSize: 100) == nil)
    }

    @Test func samplePicturesAreDeterministic() {
        #expect(PhotoProcessing.sampleJPEG(width: 100, height: 80, seed: 4) == PhotoProcessing.sampleJPEG(width: 100, height: 80, seed: 4))
    }

    static func segmentMarkers(_ jpeg: Data) -> [UInt8] {
        let bytes = [UInt8](jpeg)
        var markers: [UInt8] = []
        var index = 2
        while index + 3 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            markers.append(marker)
            if marker == 0xDA { break }
            index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
        }
        return markers
    }
}

// MARK: Wire format (what the web client must produce and accept)

@Suite struct PhotoWireFormatTests {
    func json(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    @Test func payloadsHaveTheDocumentedShape() throws {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(try json(.auth(.init(identityKey: Data([1]), name: "A", signature: Data([2]), features: ["photo-v1"])))
                == #"{"auth":{"_0":{"features":["photo-v1"],"identityKey":"AQ==","name":"A","signature":"Ag=="}}}"#)
        #expect(try json(.auth(.init(identityKey: Data([1]), name: "A", signature: Data([2]))))
                == #"{"auth":{"_0":{"identityKey":"AQ==","name":"A","signature":"Ag=="}}}"#)
        #expect(try json(.photoStart(PhotoStart(id: id, size: 3, sha256: Data([0xAB]), width: 1280, height: 960,
                                                 preview: Data([0xFF, 0xD8]), caption: "Hi")))
                == #"{"photoStart":{"_0":{"caption":"Hi","height":960,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","preview":"\/9g=","sha256":"qw==","size":3,"width":1280}}}"#)
        #expect(try json(.photoStart(PhotoStart(id: id, size: 3, sha256: Data([0xAB]), width: 0, height: 0)))
                == #"{"photoStart":{"_0":{"height":0,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sha256":"qw==","size":3,"width":0}}}"#)
        #expect(try json(.photoPiece(PhotoPiece(id: id, index: 2, data: Data([1, 2, 3]))))
                == #"{"photoPiece":{"_0":{"data":"AQID","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","index":2}}}"#)
        #expect(try json(.photoProgress(PhotoProgress(id: id, received: 3)))
                == #"{"photoProgress":{"_0":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","received":3}}}"#)
        #expect(try json(.photoCancel(id)) == #"{"photoCancel":{"_0":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#)
        #expect(try json(.photoRefuse(id)) == #"{"photoRefuse":{"_0":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#)
        // Lower-case UUIDs and unknown keys from another client are accepted.
        let fromWeb = #"{"photoProgress":{"_0":{"id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","received":1,"extra":true}}}"#
        #expect(try Payload.decode(Data(fromWeb.utf8)) == .photoProgress(PhotoProgress(id: id, received: 1)))
    }

    @Test func aFullPieceStaysFarBelowTheFrameCap() throws {
        let piece = Payload.photoPiece(PhotoPiece(id: UUID(), index: 999, data: Data(count: PhotoLimits.maxIncomingPieceBytes)))
        // Sealing adds 8 counter bytes, a 16-byte tag and the 1-byte frame kind.
        #expect(try piece.encoded().count + 25 < Frame.maxSize)
        let normal = Payload.photoPiece(PhotoPiece(id: UUID(), index: 999, data: Data(count: PhotoLimits.pieceBytes)))
        #expect(try normal.encoded().count < 6_000)
    }
}
