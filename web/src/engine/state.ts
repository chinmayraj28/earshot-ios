/**
 * The state both engines share (the real one in engine.ts and the demo in demo.ts):
 * profile, contacts, conversations, requests, the snapshot the interface reads, and the
 * message and contact operations that behave the same whether or not Bluetooth exists.
 *
 * Everything the interface can see is immutable: a change replaces the affected message,
 * array or snapshot with a new object. That keeps `getSnapshot()` safe for React's
 * `useSyncExternalStore`: it returns the very same object until something changes.
 */
import {
  Limits,
  type Availability,
  type ConnectionRequest,
  type Contact,
  type ContactID,
  type ConversationSummary,
  type DeliveryStatus,
  type Engine,
  type EngineEvent,
  type FindResult,
  type LinkState,
  type Message,
  type MessageID,
  type PeerToken,
  type Profile,
  type Snapshot,
} from "./api";
import { randomUUID } from "./bytes";
import { safetyCode } from "./crypto";
import { MAX_FRAME_SIZE, encodePayload } from "./wire";
import { isValidMessageText, sanitizedName, trimmed } from "./text";

export interface Conversation {
  messages: Message[];
  unreadCount: number;
}

const NO_MESSAGES: Message[] = Object.freeze([]) as unknown as Message[];

/** Sealed-frame overhead around the JSON: frame kind (1) + counter (8) + tag (16), plus the Bluetooth kind (1). */
const SEALED_OVERHEAD = 1 + 8 + 16 + 1;

export abstract class EngineState implements Engine {
  protected profile: Profile = { displayName: "", hasCompletedOnboarding: false };
  protected availability: Availability = "unsupported";
  protected contacts: Contact[] = [];
  protected conversations = new Map<ContactID, Conversation>();
  protected requests: ConnectionRequest[] = [];
  protected finding = false;
  protected activeConversation: ContactID | null = null;
  /** IDs of every message seen per contact, so a resent message is not stored twice. */
  protected knownMessageIDs = new Map<ContactID, Set<MessageID>>();
  protected readonly now: () => number;

  #snapshot: Snapshot | null = null;
  #listeners = new Set<() => void>();
  #eventListeners = new Set<(event: EngineEvent) => void>();

  constructor(now: () => number = Date.now) {
    this.now = now;
  }

  // MARK: Hooks for the concrete engine

  abstract ready(): Promise<void>;
  abstract findNearby(): Promise<FindResult>;
  abstract dismiss(request: PeerToken): void;
  abstract disconnect(id: ContactID): void;
  abstract eraseEverything(): Promise<void>;
  /** This browser's identity public key. */
  protected abstract ownIdentityKey(): Uint8Array;
  protected abstract linkState(id: ContactID): LinkState;
  /** Hands a waiting message to the link if one is open. */
  protected abstract transmit(id: ContactID, messageID: MessageID): void;
  /** Closes every link to this contact (used by block and remove). */
  protected abstract closeLinks(id: ContactID, reason: "blocked" | "removed"): void;
  /** Called after `send` when the contact has no open link. */
  protected afterQueued(_id: ContactID): void {}
  protected afterUnblocked(_id: ContactID): void {}
  protected persistConversation(_id: ContactID): Promise<boolean> {
    return Promise.resolve(true);
  }
  protected persistContacts(): void {}
  protected persistProfile(): void {}
  protected deleteStoredConversation(_id: ContactID): void {}

  // MARK: Reading

  getSnapshot(): Snapshot {
    if (!this.#snapshot) this.#snapshot = this.#buildSnapshot();
    return this.#snapshot;
  }

  subscribe(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  onEvent(listener: (event: EngineEvent) => void): () => void {
    this.#eventListeners.add(listener);
    return () => {
      this.#eventListeners.delete(listener);
    };
  }

  messages(id: ContactID): Message[] {
    return this.conversations.get(id)?.messages ?? NO_MESSAGES;
  }

  safetyCode(id: ContactID): string | null {
    const contact = this.contact(id);
    return contact ? safetyCode(this.ownIdentityKey(), contact.identityKey) : null;
  }

  protected contact(id: ContactID): Contact | undefined {
    return this.contacts.find((c) => c.id === id);
  }

  #buildSnapshot(): Snapshot {
    const conversations: ConversationSummary[] = this.contacts
      .map((contact) => {
        const conversation = this.conversations.get(contact.id);
        const lastMessage = conversation?.messages[conversation.messages.length - 1] ?? null;
        return {
          contact,
          lastMessage,
          unreadCount: conversation?.unreadCount ?? 0,
          link: this.linkState(contact.id),
          lastActivity: lastMessage?.timestamp ?? contact.addedAt,
        };
      })
      .sort((a, b) => b.lastActivity - a.lastActivity);
    return {
      profile: this.profile,
      availability: this.availability,
      contacts: this.contacts,
      conversations,
      requests: this.requests,
      isFinding: this.finding,
    };
  }

  /** Call after every change the interface could see. */
  protected changed(): void {
    this.#snapshot = null;
    for (const listener of [...this.#listeners]) {
      try {
        listener();
      } catch {
        // A broken listener must not break the engine.
      }
    }
  }

  protected emit(event: EngineEvent): void {
    for (const listener of [...this.#eventListeners]) {
      try {
        listener(event);
      } catch {
        // ignore
      }
    }
  }

  // MARK: Profile

  completeOnboarding(displayName: string): void {
    this.profile = { displayName: sanitizedName(displayName), hasCompletedOnboarding: true };
    this.persistProfile();
    this.changed();
  }

  setDisplayName(name: string): void {
    const clean = sanitizedName(name);
    if (!clean || clean === this.profile.displayName) return;
    this.profile = { ...this.profile, displayName: clean };
    this.persistProfile();
    this.changed();
  }

  // MARK: Messages

  send(text: string, to: ContactID): Message | null {
    const clean = trimmed(text);
    const contact = this.contact(to);
    if (!isValidMessageText(clean) || !contact || contact.isBlocked) return null;
    const message: Message = { id: randomUUID(), direction: "outgoing", text: clean, timestamp: this.now(), status: "waiting" };
    // A message whose encrypted frame would be bigger than the phone accepts could never be delivered.
    if (encodePayload({ kind: "text", id: message.id, text: clean }).length + SEALED_OVERHEAD > MAX_FRAME_SIZE) return null;
    this.appendMessage(to, message);
    this.transmit(to, message.id);
    void this.persistConversation(to);
    this.afterQueued(to);
    this.changed();
    return this.messages(to).find((m) => m.id === message.id) ?? message;
  }

  retry(messageID: MessageID, inConversation: ContactID): void {
    const message = this.messages(inConversation).find((m) => m.id === messageID);
    if (!message || message.direction !== "outgoing" || message.status !== "failed") return;
    this.setStatus(inConversation, messageID, "waiting");
    this.transmit(inConversation, messageID);
    void this.persistConversation(inConversation);
    this.afterQueued(inConversation);
    this.changed();
  }

  deleteMessage(messageID: MessageID, inConversation: ContactID): void {
    const conversation = this.conversations.get(inConversation);
    if (!conversation || !conversation.messages.some((m) => m.id === messageID)) return;
    this.conversations.set(inConversation, { ...conversation, messages: conversation.messages.filter((m) => m.id !== messageID) });
    void this.persistConversation(inConversation);
    this.changed();
  }

  setActiveConversation(id: ContactID | null): void {
    this.activeConversation = id;
    const conversation = id ? this.conversations.get(id) : undefined;
    if (id && conversation && conversation.unreadCount > 0) {
      this.conversations.set(id, { ...conversation, unreadCount: 0 });
      void this.persistConversation(id);
      this.changed();
    }
  }

  clearConversation(id: ContactID): void {
    if (!this.conversations.has(id)) return;
    this.conversations.set(id, { messages: [], unreadCount: 0 });
    void this.persistConversation(id);
    this.changed();
  }

  /** Adds a message, keeps only the newest 5,000, and records its ID. */
  protected appendMessage(id: ContactID, message: Message, countAsUnread = false): void {
    const conversation = this.conversations.get(id) ?? { messages: [], unreadCount: 0 };
    let messages = [...conversation.messages, message];
    if (messages.length > Limits.maxStoredMessages) messages = messages.slice(messages.length - Limits.maxStoredMessages);
    this.conversations.set(id, { messages, unreadCount: conversation.unreadCount + (countAsUnread ? 1 : 0) });
    this.rememberMessageID(id, message.id);
  }

  protected rememberMessageID(id: ContactID, messageID: MessageID): void {
    let known = this.knownMessageIDs.get(id);
    if (!known) {
      known = new Set();
      this.knownMessageIDs.set(id, known);
    }
    known.add(messageID);
  }

  /** Changes the status of the newest message with this ID. Returns false when nothing changed. */
  protected setStatus(id: ContactID, messageID: MessageID, status: DeliveryStatus): boolean {
    const conversation = this.conversations.get(id);
    if (!conversation) return false;
    let index = -1;
    for (let i = conversation.messages.length - 1; i >= 0; i--) {
      if (conversation.messages[i]!.id === messageID) {
        index = i;
        break;
      }
    }
    const message = conversation.messages[index];
    if (!message || message.status === status) return false;
    const messages = conversation.messages.slice();
    messages[index] = { ...message, status };
    this.conversations.set(id, { ...conversation, messages });
    return true;
  }

  /** Outgoing messages that were "sending" when a link ended go back to "waiting" and are re-sent later. */
  protected parkUnconfirmedMessages(id: ContactID): void {
    let changed = false;
    for (const message of this.messages(id)) {
      if (message.direction === "outgoing" && message.status === "sending") changed = this.setStatus(id, message.id, "waiting") || changed;
    }
    if (changed) void this.persistConversation(id);
  }

  // MARK: Contacts

  removeContact(id: ContactID): void {
    if (!this.contact(id)) return;
    this.closeLinks(id, "removed");
    this.contacts = this.contacts.filter((c) => c.id !== id);
    this.conversations.delete(id);
    this.knownMessageIDs.delete(id);
    if (this.activeConversation === id) this.activeConversation = null;
    this.persistContacts();
    this.deleteStoredConversation(id);
    this.changed();
  }

  setBlocked(blocked: boolean, id: ContactID): void {
    const contact = this.contact(id);
    if (!contact || contact.isBlocked === blocked) return;
    this.replaceContact({ ...contact, isBlocked: blocked });
    if (blocked) this.closeLinks(id, "blocked");
    this.changed();
    if (!blocked) this.afterUnblocked(id);
  }

  setVerified(verified: boolean, id: ContactID): void {
    const contact = this.contact(id);
    if (!contact || contact.isVerified === verified) return;
    this.replaceContact({ ...contact, isVerified: verified });
    this.changed();
  }

  protected replaceContact(contact: Contact): void {
    this.contacts = this.contacts.map((c) => (c.id === contact.id ? contact : c));
    this.persistContacts();
  }

  protected updateRequest(token: PeerToken, change: (request: ConnectionRequest) => ConnectionRequest | null): void {
    const index = this.requests.findIndex((r) => r.id === token);
    if (index < 0) return;
    const next = change(this.requests[index]!);
    if (next === this.requests[index]) return;
    const requests = this.requests.slice();
    if (next) requests[index] = next;
    else requests.splice(index, 1);
    this.requests = requests;
  }

  protected resetState(): void {
    this.profile = { displayName: "", hasCompletedOnboarding: false };
    this.contacts = [];
    this.conversations = new Map();
    this.knownMessageIDs = new Map();
    this.requests = [];
    this.activeConversation = null;
    this.finding = false;
  }
}
