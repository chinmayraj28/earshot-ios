import Foundation
import Testing
@testable import EarshotKit

@Suite struct CryptoTests {
    private func channels() throws -> (SecureChannel, SecureChannel) {
        let a = Handshake(), b = Handshake()
        return (try a.channel(remoteEphemeral: b.publicKey), try b.channel(remoteEphemeral: a.publicKey))
    }

    @Test func channelCarriesDataBothWays() throws {
        var (a, b) = try channels()
        let one = try a.seal(Data("hello".utf8))
        let two = try a.seal(Data("again".utf8))
        #expect(try b.open(one) == Data("hello".utf8))
        #expect(try b.open(two) == Data("again".utf8))
        let back = try b.seal(Data("hi".utf8))
        #expect(try a.open(back) == Data("hi".utf8))
    }

    @Test func ciphertextDoesNotContainPlaintext() throws {
        var (a, _) = try channels()
        let secret = Data("meet me by the stairs".utf8)
        #expect(try a.seal(secret).range(of: secret) == nil)
    }

    @Test func tamperedFrameIsRejected() throws {
        var (a, b) = try channels()
        var frame = try a.seal(Data("hello".utf8))
        frame[frame.count - 1] ^= 0x01
        #expect(throws: (any Error).self) { try b.open(frame) }
    }

    @Test func replayedFrameIsRejected() throws {
        var (a, b) = try channels()
        let frame = try a.seal(Data("hello".utf8))
        _ = try b.open(frame)
        #expect(throws: CryptoError.replayed) { try b.open(frame) }
    }

    @Test func frameCannotBeReflectedBackToSender() throws {
        var (a, _) = try channels()
        let frame = try a.seal(Data("hello".utf8))
        #expect(throws: (any Error).self) { try a.open(frame) }
    }

    @Test func outsiderCannotReadTheChannel() throws {
        var (a, _) = try channels()
        var (_, eavesdropper) = try channels()
        let frame = try a.seal(Data("hello".utf8))
        #expect(throws: (any Error).self) { try eavesdropper.open(frame) }
    }

    @Test func echoedEphemeralKeyIsRejected() {
        let a = Handshake()
        #expect(throws: CryptoError.reflectedKey) { try a.channel(remoteEphemeral: a.publicKey) }
    }

    @Test func signatureVerifiesOnlyForSignerAndTranscript() throws {
        let identity = Identity(), other = Identity()
        let transcript = Handshake.transcript(signerEphemeral: Data(repeating: 1, count: 32), peerEphemeral: Data(repeating: 2, count: 32))
        let signature = try identity.sign(transcript)
        #expect(Identity.verify(signature: signature, of: transcript, identityKey: identity.publicKey))
        #expect(!Identity.verify(signature: signature, of: transcript, identityKey: other.publicKey))
        let swapped = Handshake.transcript(signerEphemeral: Data(repeating: 2, count: 32), peerEphemeral: Data(repeating: 1, count: 32))
        #expect(!Identity.verify(signature: signature, of: swapped, identityKey: identity.publicKey))
    }

    @Test func identitySurvivesStorage() throws {
        let identity = Identity()
        let restored = try Identity(rawRepresentation: identity.rawRepresentation)
        #expect(restored.publicKey == identity.publicKey)
        #expect(restored.contactID == identity.contactID)
        #expect(identity.contactID.rawValue.count == 32)
    }

    @Test func safetyCodeIsSameOnBothPhones() {
        let a = Identity().publicKey, b = Identity().publicKey, c = Identity().publicKey
        let code = SafetyCode.make(a, b)
        #expect(code == SafetyCode.make(b, a))
        #expect(code != SafetyCode.make(a, c))
        #expect(code.wholeMatch(of: /\d{3} \d{3} \d{3}/) != nil)
    }

    @Test func discoveryTagIsRecognisedOnlyWithTheKey() {
        let key = Identity().publicKey, otherKey = Identity().publicKey
        let nonce = DiscoveryTag.makeNonce(), nextNonce = DiscoveryTag.makeNonce()
        let tag = DiscoveryTag.make(identityKey: key, nonce: nonce)
        #expect(tag.count == DiscoveryTag.tagLength)
        #expect(tag == DiscoveryTag.make(identityKey: key, nonce: nonce))
        #expect(tag != DiscoveryTag.make(identityKey: otherKey, nonce: nonce))
        // A new session produces an unrelated tag, so a stranger cannot link the two.
        #expect(tag != DiscoveryTag.make(identityKey: key, nonce: nextNonce))
    }
}

@Suite struct WireTests {
    @Test func framesRoundTrip() throws {
        let hello = Frame.hello(version: 1, ephemeralKey: Data(repeating: 7, count: 32))
        #expect(try Frame(decoding: hello.encoded()) == hello)
        let sealed = Frame.sealed(Data([1, 2, 3]))
        #expect(try Frame(decoding: sealed.encoded()) == sealed)
    }

    @Test func malformedFramesAreRejected() {
        #expect(throws: (any Error).self) { try Frame(decoding: Data()) }
        #expect(throws: (any Error).self) { try Frame(decoding: Data([9, 1, 2])) }
        #expect(throws: (any Error).self) { try Frame(decoding: Data([1, 1, 2, 3])) }
        #expect(throws: (any Error).self) { try Frame(decoding: Data([2]) + Data(count: Frame.maxSize)) }
    }

    @Test func framesDecodeFromDataSlices() throws {
        let padded = Data([0, 0]) + Frame.sealed(Data([5, 6])).encoded()
        #expect(try Frame(decoding: padded.dropFirst(2)) == .sealed(Data([5, 6])))
    }

    @Test func payloadsRoundTrip() throws {
        let id = UUID()
        for payload in [Payload.text(.init(id: id, text: "héllo 👋")), .ack(id), .bye,
                        .auth(.init(identityKey: Data([1]), name: "A", signature: Data([2])))] {
            #expect(try Payload.decode(payload.encoded()) == payload)
        }
    }

    @Test func oversizedInviteContextIsIgnored() {
        #expect(InviteContext.decode(Data(count: 5000)) == nil)
        let context = InviteContext(name: "A", nonce: Data([1]), tag: Data([2]))
        #expect(InviteContext.decode(context.encoded()) == context)
    }

    @Test func namesAreCleaned() {
        #expect(Limits.sanitizedName("  Maya \n Okafor\t ") == "Maya Okafor")
        #expect(Limits.sanitizedName(String(repeating: "x", count: 100)).count == Limits.maxNameLength)
        #expect(Limits.sanitizedName(" \n ").isEmpty)
    }
}
