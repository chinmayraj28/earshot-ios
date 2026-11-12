/**
 * The contract between the Earshot web engine and the web interface.
 *
 * It mirrors the iOS `Messenger` class (EarshotKit/Sources/EarshotKit/Messenger.swift and
 * Models.swift) so both apps behave the same way. The interface only ever talks to this
 * file; it never touches Bluetooth, encryption or storage directly.
 *
 * One big difference from the phone app: a browser can only START Bluetooth connections.
 * It cannot announce itself, so phones cannot find it and it never receives a request
 * from a stranger. The person must click a button and pick a phone in the browser's own
 * device chooser. See `findNearby`.
 */

/** Hex string derived from the contact's identity key. Same value the iOS app computes. */
export type ContactID = string;
/** Short-lived handle for one Bluetooth device picked in this browser session. */
export type PeerToken = string;
/** Uppercase UUID string, e.g. "3F2504E0-4F89-11D3-9A0C-0305E82C3301" (Swift's format). */
export type MessageID = string;

export interface Contact {
  id: ContactID;
  displayName: string;
  /** Ed25519 public key, 32 bytes. */
  identityKey: Uint8Array;
  /** Milliseconds since 1970. */
  addedAt: number;
  isBlocked: boolean;
  /** True once the person has compared safety codes with this contact. */
  isVerified: boolean;
}

/**
 * waiting   – not sent yet: the phone is not connected. Sent automatically on reconnect.
 * sending   – handed to the Bluetooth link; no receipt yet.
 * delivered – the phone confirmed it received and stored the message.
 * failed    – no receipt arrived in time, or sending failed. Needs a manual retry.
 */
export type DeliveryStatus = "waiting" | "sending" | "delivered" | "failed";

export interface Message {
  id: MessageID;
  direction: "incoming" | "outgoing";
  text: string;
  /** Milliseconds since 1970: created (outgoing) or received (incoming) here. */
  timestamp: number;
  /** Only meaningful for outgoing messages; incoming ones are always "delivered". */
  status: DeliveryStatus;
}

/**
 * outOfRange – no Bluetooth connection to this contact's phone.
 * connecting – a link is being opened or re-opened.
 * connected  – secure link open: messages are delivered immediately.
 *
 * There is no "in range" state: a browser cannot scan in the background, so it does not
 * know a phone is nearby until the person picks it.
 */
export type LinkState = "outOfRange" | "connecting" | "connected";

export interface ConversationSummary {
  contact: Contact;
  lastMessage: Message | null;
  unreadCount: number;
  link: LinkState;
  /** lastMessage.timestamp, or contact.addedAt when there are no messages. */
  lastActivity: number;
}

export type RequestFailure =
  /** Declined, not answered in time, or out of range. These cannot be told apart. */
  | "noAnswer"
  /** The link dropped while the two devices were setting up. */
  | "connectionLost"
  /** The other device could not prove who it is. */
  | "verificationFailed"
  /** The other device runs an incompatible version of Earshot. */
  | "incompatibleVersion";

/** An outgoing request to start a conversation with the phone the person just picked. */
export interface ConnectionRequest {
  id: PeerToken;
  /** The name the phone announces. */
  displayName: string;
  state:
    /** Waiting for the person holding the phone to accept. */
    | { kind: "waiting" }
    /** Accepted; the secure link is being set up. */
    | { kind: "connecting" }
    /** Done. The conversation is ready. */
    | { kind: "connected"; contactID: ContactID }
    | { kind: "failed"; failure: RequestFailure };
}

export interface Profile {
  /** The name shown to the other person. Empty until onboarding is finished. */
  displayName: string;
  hasCompletedOnboarding: boolean;
}

/**
 * ready        – Web Bluetooth is usable.
 * unsupported  – this browser has no Web Bluetooth (Safari, Firefox, every iPhone browser).
 * insecure     – the page is not served over https or localhost, so the browser blocks Bluetooth.
 * bluetoothOff – the computer's Bluetooth is switched off or missing.
 */
export type Availability = "ready" | "unsupported" | "insecure" | "bluetoothOff";

export type FindResult =
  /** A phone was picked. Either a request was started (new) or a reconnection began (saved contact). */
  | { kind: "started"; peer: PeerToken; contactID: ContactID | null }
  /** The person closed the browser's chooser without picking anything. */
  | { kind: "cancelled" }
  /** The picked device did not answer like an Earshot phone, or could not be reached. */
  | { kind: "failed"; reason: "notEarshot" | "unreachable" | "unavailable" };

export type EngineEvent =
  | { kind: "connected"; contactID: ContactID }
  | { kind: "messageReceived"; contactID: ContactID; message: Message };

/** An immutable picture of everything the interface shows. A new object after every change. */
export interface Snapshot {
  profile: Profile;
  availability: Availability;
  contacts: Contact[];
  /** Sorted by lastActivity, newest first. Blocked contacts are included (flagged on the contact). */
  conversations: ConversationSummary[];
  requests: ConnectionRequest[];
  /** True while the browser's device chooser is open or the picked phone is being read. */
  isFinding: boolean;
}

export interface Engine {
  /** Loads saved state. Must resolve before anything else is used. */
  ready(): Promise<void>;

  /** Current snapshot. Returns the same object until something changes (safe for useSyncExternalStore). */
  getSnapshot(): Snapshot;
  /** Calls `listener` after every change. Returns an unsubscribe function. */
  subscribe(listener: () => void): () => void;
  /** Calls `listener` for things worth a notification. Returns an unsubscribe function. */
  onEvent(listener: (event: EngineEvent) => void): () => void;

  messages(id: ContactID): Message[];
  /** "123 456 789", identical to what the phone shows for this contact. */
  safetyCode(id: ContactID): string | null;

  completeOnboarding(displayName: string): void;
  setDisplayName(name: string): void;

  /**
   * Opens the browser's Bluetooth chooser (MUST be called directly from a click handler),
   * then reads the picked phone. If it is a saved contact it reconnects silently; otherwise
   * it sends a connection request that the person holding the phone must accept.
   */
  findNearby(): Promise<FindResult>;
  /** Removes a finished or failed request from the list, or cancels a waiting one. */
  dismiss(request: PeerToken): void;
  /** Closes the link to a contact. Messages written afterwards wait for the next connection. */
  disconnect(id: ContactID): void;

  /** Returns null when the text is empty, too long, or the contact is unknown or blocked. */
  send(text: string, to: ContactID): Message | null;
  retry(message: MessageID, inConversation: ContactID): void;
  deleteMessage(message: MessageID, inConversation: ContactID): void;
  /** Tells the engine which chat is on screen so its messages are not counted as unread. */
  setActiveConversation(id: ContactID | null): void;
  clearConversation(id: ContactID): void;
  removeContact(id: ContactID): void;
  setBlocked(blocked: boolean, id: ContactID): void;
  setVerified(verified: boolean, id: ContactID): void;
  /** Deletes the identity, contacts and messages from this browser. Cannot be undone. */
  eraseEverything(): Promise<void>;
}

export const Limits = {
  maxMessageLength: 2000,
  maxNameLength: 32,
  maxNameBytes: 96,
  maxStoredMessages: 5000,
} as const;
