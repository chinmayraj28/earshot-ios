/**
 * Where the engine keeps things between visits: this browser's IndexedDB, nowhere else.
 *
 * Database "earshot", two object stores:
 * - "meta": key "identity" (the 32-byte Ed25519 seed), "profile", "contacts".
 * - "conversations": one record per contact ID, `{ messages, unreadCount }`.
 *
 * Example: after a reload, `load()` returns the same identity seed, so the safety codes and
 * contact IDs on the phone still match this browser.
 */
import type { Contact, ContactID, DeliveryStatus, Message, Profile } from "./api";

export interface StoredConversation {
  messages: Message[];
  unreadCount: number;
}

export interface StoredState {
  identitySeed: Uint8Array | null;
  profile: Profile;
  contacts: Contact[];
  conversations: Map<ContactID, StoredConversation>;
}

export interface Storage {
  load(): Promise<StoredState>;
  saveIdentity(seed: Uint8Array): Promise<void>;
  saveProfile(profile: Profile): Promise<void>;
  saveContacts(contacts: Contact[]): Promise<void>;
  saveConversation(id: ContactID, conversation: StoredConversation): Promise<void>;
  deleteConversation(id: ContactID): Promise<void>;
  eraseAll(): Promise<void>;
}

export function emptyState(): StoredState {
  return {
    identitySeed: null,
    profile: { displayName: "", hasCompletedOnboarding: false },
    contacts: [],
    conversations: new Map(),
  };
}

// MARK: Checking what comes back from storage

const STATUSES: readonly DeliveryStatus[] = ["waiting", "sending", "delivered", "failed"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toBytes(value: unknown): Uint8Array | null {
  if (value instanceof Uint8Array) return new Uint8Array(value);
  if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
  return null;
}

function readProfile(value: unknown): Profile {
  if (!isRecord(value) || typeof value.displayName !== "string") return emptyState().profile;
  return { displayName: value.displayName, hasCompletedOnboarding: value.hasCompletedOnboarding === true };
}

function readContact(value: unknown): Contact | null {
  if (!isRecord(value)) return null;
  const identityKey = toBytes(value.identityKey);
  if (typeof value.id !== "string" || typeof value.displayName !== "string" || !identityKey || identityKey.length !== 32) return null;
  return {
    id: value.id,
    displayName: value.displayName,
    identityKey,
    addedAt: typeof value.addedAt === "number" ? value.addedAt : 0,
    isBlocked: value.isBlocked === true,
    isVerified: value.isVerified === true,
  };
}

function readMessage(value: unknown): Message | null {
  if (!isRecord(value)) return null;
  const { id, direction, text, timestamp, status } = value;
  if (typeof id !== "string" || typeof text !== "string" || typeof timestamp !== "number") return null;
  if (direction !== "incoming" && direction !== "outgoing") return null;
  if (!STATUSES.includes(status as DeliveryStatus)) return null;
  return { id, direction, text, timestamp, status: status as DeliveryStatus };
}

function readConversation(value: unknown): StoredConversation {
  if (!isRecord(value) || !Array.isArray(value.messages)) return { messages: [], unreadCount: 0 };
  const messages = value.messages.map(readMessage).filter((m): m is Message => m !== null);
  const unread = typeof value.unreadCount === "number" && value.unreadCount > 0 ? Math.floor(value.unreadCount) : 0;
  return { messages, unreadCount: unread };
}

function copyContact(contact: Contact): Contact {
  return { ...contact, identityKey: new Uint8Array(contact.identityKey) };
}

function copyConversation(conversation: StoredConversation): StoredConversation {
  return { messages: conversation.messages.map((m) => ({ ...m })), unreadCount: conversation.unreadCount };
}

// MARK: In memory (tests, demo, and the fallback when IndexedDB cannot be opened)

export class MemoryStorage implements Storage {
  #state = emptyState();
  /** Set to make every save fail, to test what happens when storing a message fails. */
  failWrites = false;

  async load(): Promise<StoredState> {
    const s = this.#state;
    return {
      identitySeed: s.identitySeed ? new Uint8Array(s.identitySeed) : null,
      profile: { ...s.profile },
      contacts: s.contacts.map(copyContact),
      conversations: new Map([...s.conversations].map(([id, c]) => [id, copyConversation(c)])),
    };
  }

  #check(): void {
    if (this.failWrites) throw new Error("storage write failed");
  }

  async saveIdentity(seed: Uint8Array): Promise<void> {
    this.#check();
    this.#state.identitySeed = new Uint8Array(seed);
  }

  async saveProfile(profile: Profile): Promise<void> {
    this.#check();
    this.#state.profile = { ...profile };
  }

  async saveContacts(contacts: Contact[]): Promise<void> {
    this.#check();
    this.#state.contacts = contacts.map(copyContact);
  }

  async saveConversation(id: ContactID, conversation: StoredConversation): Promise<void> {
    this.#check();
    this.#state.conversations.set(id, copyConversation(conversation));
  }

  async deleteConversation(id: ContactID): Promise<void> {
    this.#state.conversations.delete(id);
  }

  async eraseAll(): Promise<void> {
    this.#state = emptyState();
  }
}

// MARK: IndexedDB

const META = "meta";
const CONVERSATIONS = "conversations";

function request<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("IndexedDB transaction failed"));
    tx.onabort = () => reject(tx.error ?? new Error("IndexedDB transaction aborted"));
  });
}

export class IndexedDBStorage implements Storage {
  #db: Promise<IDBDatabase> | null = null;

  constructor(
    private readonly name = "earshot",
    private readonly factory: IDBFactory = globalThis.indexedDB,
  ) {}

  #open(): Promise<IDBDatabase> {
    if (!this.#db) {
      this.#db = new Promise<IDBDatabase>((resolve, reject) => {
        if (!this.factory) {
          reject(new Error("IndexedDB is not available"));
          return;
        }
        const req = this.factory.open(this.name, 1);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains(META)) db.createObjectStore(META);
          if (!db.objectStoreNames.contains(CONVERSATIONS)) db.createObjectStore(CONVERSATIONS);
        };
        req.onsuccess = () => {
          const db = req.result;
          // Another tab upgrading the database: let go so it can proceed.
          db.onversionchange = () => db.close();
          resolve(db);
        };
        req.onerror = () => reject(req.error ?? new Error("IndexedDB open failed"));
        req.onblocked = () => reject(new Error("IndexedDB open blocked"));
      });
      this.#db.catch(() => {
        this.#db = null;
      });
    }
    return this.#db;
  }

  async #write(store: string, action: (s: IDBObjectStore) => void): Promise<void> {
    const db = await this.#open();
    const tx = db.transaction(store, "readwrite");
    action(tx.objectStore(store));
    await transactionDone(tx);
  }

  async load(): Promise<StoredState> {
    const db = await this.#open();
    const tx = db.transaction([META, CONVERSATIONS], "readonly");
    const meta = tx.objectStore(META);
    const convs = tx.objectStore(CONVERSATIONS);
    const [identity, profile, contacts, keys, values] = await Promise.all([
      request(meta.get("identity")),
      request(meta.get("profile")),
      request(meta.get("contacts")),
      request(convs.getAllKeys()),
      request(convs.getAll()),
    ]);
    const seed = toBytes(identity);
    const conversations = new Map<ContactID, StoredConversation>();
    keys.forEach((key, i) => {
      if (typeof key === "string") conversations.set(key, readConversation(values[i]));
    });
    return {
      identitySeed: seed && seed.length === 32 ? seed : null,
      profile: readProfile(profile),
      contacts: Array.isArray(contacts) ? contacts.map(readContact).filter((c): c is Contact => c !== null) : [],
      conversations,
    };
  }

  saveIdentity(seed: Uint8Array): Promise<void> {
    return this.#write(META, (s) => s.put(new Uint8Array(seed), "identity"));
  }

  saveProfile(profile: Profile): Promise<void> {
    return this.#write(META, (s) => s.put({ ...profile }, "profile"));
  }

  saveContacts(contacts: Contact[]): Promise<void> {
    return this.#write(META, (s) => s.put(contacts.map(copyContact), "contacts"));
  }

  saveConversation(id: ContactID, conversation: StoredConversation): Promise<void> {
    return this.#write(CONVERSATIONS, (s) => s.put(copyConversation(conversation), id));
  }

  deleteConversation(id: ContactID): Promise<void> {
    return this.#write(CONVERSATIONS, (s) => s.delete(id));
  }

  async eraseAll(): Promise<void> {
    const db = await this.#open();
    const tx = db.transaction([META, CONVERSATIONS], "readwrite");
    tx.objectStore(META).clear();
    tx.objectStore(CONVERSATIONS).clear();
    await transactionDone(tx);
  }
}
