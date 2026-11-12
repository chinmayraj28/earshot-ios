import Foundation

/// Stable identifier for a person you have connected with.
/// Derived from their identity public key, so it cannot be claimed by someone else.
public struct ContactID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Short-lived handle for a nearby device. It changes every time the other
/// person's app starts, so it cannot be used to follow someone around.
public struct PeerToken: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct Contact: Identifiable, Codable, Sendable, Hashable {
    public let id: ContactID
    public var displayName: String
    /// Ed25519 public key that proves this contact's identity on every connection.
    public let identityKey: Data
    public var addedAt: Date
    public var isBlocked: Bool
    /// True once the user has compared safety codes with this person.
    public var isVerified: Bool

    public init(id: ContactID, displayName: String, identityKey: Data, addedAt: Date = Date(),
                isBlocked: Bool = false, isVerified: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.identityKey = identityKey
        self.addedAt = addedAt
        self.isBlocked = isBlocked
        self.isVerified = isVerified
    }
}

public enum DeliveryStatus: String, Codable, Sendable {
    /// Not sent yet: the other phone is not connected. Sent automatically on reconnect.
    case waiting
    /// Handed to the radio link; no receipt from the other phone yet.
    case sending
    /// The other phone confirmed it received and stored the message.
    case delivered
    /// No receipt arrived in time, or the message could not be sent. Needs a manual retry.
    case failed
}

public struct Message: Identifiable, Codable, Sendable, Hashable {
    public enum Direction: String, Codable, Sendable { case incoming, outgoing }

    public let id: UUID
    public let direction: Direction
    public let text: String
    /// When this phone created (outgoing) or received (incoming) the message.
    public let timestamp: Date
    /// Only meaningful for outgoing messages. Incoming messages are always `.delivered`.
    public var status: DeliveryStatus
    /// Set when the message is a photo. `text` is then the optional caption (often empty).
    /// Optional, so conversations saved by earlier versions (which have no such key) still load.
    public let photo: PhotoAttachment?

    public init(id: UUID = UUID(), direction: Direction, text: String, timestamp: Date = Date(),
                status: DeliveryStatus, photo: PhotoAttachment? = nil) {
        self.id = id
        self.direction = direction
        self.text = text
        self.timestamp = timestamp
        self.status = status
        self.photo = photo
    }
}

/// A photo stored on this phone as its own file (see `AttachmentStore`).
public struct PhotoAttachment: Codable, Sendable, Hashable {
    /// The file's name inside the attachment folder, for example `"6F9619FF-….jpg"`.
    public let fileName: String
    public let byteCount: Int
    /// Real pixel size, read from the file itself (never taken from the sender's word).
    public let width: Int
    public let height: Int

    public init(fileName: String, byteCount: Int, width: Int, height: Int) {
        self.fileName = fileName
        self.byteCount = byteCount
        self.width = width
        self.height = height
    }
}

public struct Conversation: Codable, Sendable, Equatable {
    public var messages: [Message]
    public var unreadCount: Int

    public init(messages: [Message] = [], unreadCount: Int = 0) {
        self.messages = messages
        self.unreadCount = unreadCount
    }
}

public struct ConversationSummary: Identifiable, Sendable, Equatable {
    public let contact: Contact
    public let lastMessage: Message?
    public let unreadCount: Int
    public let link: LinkState
    public var id: ContactID { contact.id }
    public var lastActivity: Date { lastMessage?.timestamp ?? contact.addedAt }
}

/// How reachable a saved contact is right now.
public enum LinkState: Int, Sendable, Comparable {
    /// Not detected nearby.
    case outOfRange
    /// Detected nearby, but no secure link is open yet.
    case inRange
    /// A link is being opened or re-opened.
    case connecting
    /// Secure link open: messages are delivered immediately.
    case connected

    public static func < (lhs: LinkState, rhs: LinkState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A device running Earshot that is currently detected nearby.
public struct NearbyPeer: Identifiable, Sendable, Hashable {
    public let id: PeerToken
    public let displayName: String
    /// Set when the device was recognised as one of your saved contacts.
    public let contactID: ContactID?
}

/// A request to start a conversation with someone new. Nothing is exchanged
/// until the receiving person accepts.
public struct ConnectionRequest: Identifiable, Sendable, Equatable {
    public enum Direction: Sendable { case incoming, outgoing }

    public enum Failure: Sendable, Equatable {
        /// The other person declined, did not answer in time, or moved out of range.
        /// iOS does not tell these apart, so neither do we.
        case noAnswer
        /// The link dropped while the two phones were setting up.
        case connectionLost
        /// The other phone could not prove who it is.
        case verificationFailed
        /// The other phone runs an incompatible version of Earshot.
        case incompatibleVersion
    }

    public enum State: Sendable, Equatable {
        /// Incoming: waiting for you to accept or decline.
        case pending
        /// Outgoing: waiting for the other person to accept.
        case waiting
        /// Accepted by both sides; the secure link is being set up.
        case connecting
        /// Done. The conversation is ready.
        case connected(ContactID)
        case failed(Failure)
    }

    public let id: PeerToken
    public let direction: Direction
    public let displayName: String
    public var state: State
}

public struct Profile: Codable, Sendable, Equatable {
    /// The name shown to people nearby. Empty until onboarding is finished.
    public var displayName: String
    /// When false this phone does not announce itself; it can still find others.
    public var isVisible: Bool
    public var hasCompletedOnboarding: Bool

    public init(displayName: String = "", isVisible: Bool = true, hasCompletedOnboarding: Bool = false) {
        self.displayName = displayName
        self.isVisible = isVisible
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

public enum TransportProblem: Sendable, Equatable {
    /// The user has not allowed Local Network access in Settings (Simulator and Mac only).
    case localNetworkDenied
    /// Bluetooth is switched off.
    case bluetoothOff
    /// The user has not allowed Earshot to use Bluetooth.
    case bluetoothDenied
    /// This device has no usable Bluetooth LE radio (for example the iOS Simulator).
    case bluetoothUnsupported
    /// The radios could not start. Carries the system's description.
    case failedToStart(String)

    /// True when the radio layer keeps watching and reports `.ready` once the person
    /// has fixed the problem (switched Bluetooth on, granted the permission).
    public var recoversByItself: Bool {
        switch self {
        case .localNetworkDenied, .bluetoothOff, .bluetoothDenied: true
        case .bluetoothUnsupported, .failedToStart: false
        }
    }
}

public enum Availability: Sendable, Equatable {
    /// Not looking for anyone (app just launched, or in the background).
    case off
    /// Discovering nearby phones and, if visible, discoverable by them.
    case on
    case unavailable(TransportProblem)
}

public enum Limits {
    public static let maxMessageLength = 2000
    public static let maxNameLength = 32
    public static let maxNameBytes = 96
    /// Oldest messages beyond this are dropped from a conversation.
    public static let maxStoredMessages = 5000

    /// Cleans up a name typed by a user or received from another device.
    public static func sanitizedName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        var name = String(collapsed.prefix(maxNameLength))
        // Names are also announced over Bonjour, which limits each value to 255 bytes.
        while name.utf8.count > maxNameBytes { name.removeLast() }
        return name
    }
}
