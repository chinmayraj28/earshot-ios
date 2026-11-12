/**
 * A pretend engine for screenshots, interface tests and trying the app without a phone.
 * No Bluetooth, nothing stored, no randomness: the same calls always give the same results
 * at the same times, so the interface's tests can rely on it.
 *
 * Timeline of `findNearby()` with the default "newContact" outcome:
 *   0 ms     isFinding = true (pretend chooser)
 *   300 ms   returns { kind: "started" }; a request "waiting" appears
 *   1800 ms  the pretend phone accepts: request "connecting"
 *   2200 ms  connected: new contact, `connected` event
 *   3700 ms  the new contact sends one greeting (`messageReceived` event)
 *
 * Other outcomes can be queued with `options.findOutcomes`, e.g. ["declined", "savedContact"].
 */
import type { ContactID, FindResult, LinkState, Message, MessageID, PeerToken, RequestFailure } from "./api";
import { contactIDFor, identityFromSeed } from "./crypto";
import { EngineState } from "./state";

export type DemoScenario = "populated" | "empty" | "firstRun";

export type DemoFindOutcome =
  /** A new phone whose person accepts. */
  | "newContact"
  /** Re-links the out-of-range saved contact (Jonas in "populated"); his waiting messages go out. */
  | "savedContact"
  /** A new phone whose person never accepts: the request fails with "noAnswer". */
  | "declined"
  /** A request appears, then fails with this RequestFailure after `acceptMs`. */
  | "connectionLost"
  | "verificationFailed"
  | "incompatibleVersion"
  /** findNearby returns { kind: "cancelled" } / { kind: "failed", reason } without any request. */
  | "cancelled"
  | "notEarshot"
  | "unreachable"
  | "unavailable";

export interface DemoOptions {
  findOutcomes?: DemoFindOutcome[];
  /** When true, a connected contact answers each message once, `replyMs` after it was delivered. Default false. */
  autoReply?: boolean;
  /** Clock for timestamps. Default `Date.now`. */
  now?: () => number;
}

export const DemoTiming = {
  chooserMs: 300,
  acceptMs: 1_500,
  connectMs: 400,
  greetingMs: 1_500,
  reconnectMs: 800,
  deliverMs: 700,
  replyMs: 2_000,
} as const;

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

function seed(n: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, (_, i) => (n * 31 + i) & 0xff);
}

function demoUUID(n: number): string {
  return `00000000-0000-4000-8000-${n.toString(16).toUpperCase().padStart(12, "0")}`;
}

/** People who "appear" when findNearby is used, in this order. */
const NEW_PEOPLE = [
  { name: "Noor Haddad", greeting: "Hi! Got your request. I'm by the info tent." },
  { name: "Theo Brandt", greeting: "Hey, connected. Which exit are you near?" },
  { name: "Ines Duarte", greeting: "Hello! Signal's dead here too." },
];

type Line = [direction: "in" | "out", text: string, minutesAgo: number, status?: Message["status"]];

export class DemoEngine extends EngineState {
  readonly #identityKey = identityFromSeed(seed(1)).publicKey;
  #links = new Map<ContactID, LinkState>();
  #timers = new Set<ReturnType<typeof setTimeout>>();
  #requestTimers = new Map<PeerToken, Array<ReturnType<typeof setTimeout>>>();
  #outcomes: DemoFindOutcome[];
  readonly #autoReply: boolean;
  #nextPerson = 0;
  #nextPeer = 0;
  #nextMessage = 1;
  readonly #scenario: DemoScenario;

  constructor(scenario: DemoScenario, options: DemoOptions = {}) {
    super(options.now);
    this.#scenario = scenario;
    this.#outcomes = [...(options.findOutcomes ?? [])];
    this.#autoReply = options.autoReply === true;
    this.availability = "ready";
    this.#seed(scenario);
  }

  #seed(scenario: DemoScenario): void {
    this.resetState();
    this.#links.clear();
    if (scenario === "firstRun") return;
    this.profile = { displayName: "Chinmay", hasCompletedOnboarding: true };
    if (scenario === "empty") return;
    const now = this.now();
    this.#addSeeded(10, "Maya Okafor", "connected", { verified: true }, now, [
      ["in", "Train's stuck in the tunnel. Zero bars.", 34],
      ["out", "Same in carriage 4. Are you near the front?", 33],
      ["in", "Carriage 2. They say twenty minutes.", 31],
      ["out", "OK. Meet on the platform by the stairs when we get in?", 30],
      ["in", "Deal. I'll wait by the stairs.", 29],
    ]);
    this.#addSeeded(11, "Jonas Weber", "outOfRange", {}, now, [
      ["in", "I'm at the food trucks near the main stage.", 26 * 60],
      ["out", "Which truck are you at?", 25 * 60, "waiting"],
    ]);
    this.#addSeeded(12, "Priya Raman", "connected", { unread: 2 }, now, [
      ["in", "Are you still in the building?", 8],
      ["in", "Doors on the east side are open now.", 6],
    ]);
    this.#addSeeded(13, "Sam Lee", "outOfRange", { blocked: true }, now, [["in", "You around later?", 3 * DAY / MINUTE]]);
  }

  #addSeeded(
    n: number,
    name: string,
    link: LinkState,
    flags: { verified?: boolean; blocked?: boolean; unread?: number },
    now: number,
    lines: Line[],
  ): void {
    const identityKey = identityFromSeed(seed(n)).publicKey;
    const id = contactIDFor(identityKey);
    this.contacts = [
      ...this.contacts,
      { id, displayName: name, identityKey, addedAt: now - 3 * DAY, isBlocked: flags.blocked === true, isVerified: flags.verified === true },
    ];
    const messages: Message[] = lines.map(([direction, text, ago, status]) => ({
      id: demoUUID(this.#nextMessage++),
      direction: direction === "in" ? "incoming" : "outgoing",
      text,
      timestamp: now - ago * MINUTE,
      status: status ?? "delivered",
    }));
    this.conversations.set(id, { messages, unreadCount: flags.unread ?? 0 });
    this.knownMessageIDs.set(id, new Set(messages.map((m) => m.id)));
    this.#links.set(id, link);
  }

  ready(): Promise<void> {
    return Promise.resolve();
  }

  protected ownIdentityKey(): Uint8Array {
    return this.#identityKey;
  }

  protected linkState(id: ContactID): LinkState {
    return this.#links.get(id) ?? "outOfRange";
  }

  #later(ms: number, action: () => void, token?: PeerToken): void {
    const timer = setTimeout(() => {
      this.#timers.delete(timer);
      action();
    }, ms);
    this.#timers.add(timer);
    if (token) this.#requestTimers.set(token, [...(this.#requestTimers.get(token) ?? []), timer]);
  }

  protected transmit(id: ContactID, messageID: MessageID): void {
    if (this.#links.get(id) !== "connected") return;
    this.setStatus(id, messageID, "sending");
    this.#later(DemoTiming.deliverMs, () => {
      if (this.messages(id).find((m) => m.id === messageID)?.status !== "sending") return;
      const delivered = this.#links.get(id) === "connected";
      this.setStatus(id, messageID, delivered ? "delivered" : "waiting");
      this.changed();
      if (delivered && this.#autoReply) this.#later(DemoTiming.replyMs, () => this.#receive(id, "Got it 👍"));
    });
  }

  protected closeLinks(id: ContactID): void {
    this.#links.set(id, "outOfRange");
    this.parkUnconfirmedMessages(id);
  }

  async findNearby(): Promise<FindResult> {
    if (this.finding) return { kind: "cancelled" };
    if (!this.profile.displayName) return { kind: "failed", reason: "unavailable" };
    this.finding = true;
    this.changed();
    await new Promise<void>((resolve) => this.#later(DemoTiming.chooserMs, resolve));
    this.finding = false;
    const outcome = this.#outcomes.shift() ?? "newContact";
    let result: FindResult;
    switch (outcome) {
      case "cancelled":
        result = { kind: "cancelled" };
        break;
      case "notEarshot":
      case "unreachable":
      case "unavailable":
        result = { kind: "failed", reason: outcome };
        break;
      case "savedContact": {
        const saved = this.contacts.find((c) => !c.isBlocked && this.linkState(c.id) === "outOfRange");
        result = saved ? this.#reconnect(saved.id) : this.#request(null);
        break;
      }
      case "declined":
        result = this.#request("noAnswer");
        break;
      case "connectionLost":
      case "verificationFailed":
      case "incompatibleVersion":
        result = this.#request(outcome);
        break;
      case "newContact":
        result = this.#request(null);
        break;
    }
    this.changed();
    return result;
  }

  #reconnect(id: ContactID): FindResult {
    const peer = `demo-peer-${++this.#nextPeer}`;
    this.#links.set(id, "connecting");
    this.#later(DemoTiming.reconnectMs, () => {
      if (this.#links.get(id) !== "connecting") return;
      this.#connected(id);
    });
    return { kind: "started", peer, contactID: id };
  }

  #connected(id: ContactID): void {
    this.#links.set(id, "connected");
    this.emit({ kind: "connected", contactID: id });
    for (const message of this.messages(id)) {
      if (message.direction === "outgoing" && message.status === "waiting") this.transmit(id, message.id);
    }
    this.changed();
  }

  /** Starts a pretend request. `failure` set: it fails that way after `acceptMs` instead of connecting. */
  #request(failure: RequestFailure | null): FindResult {
    const person = NEW_PEOPLE[this.#nextPerson % NEW_PEOPLE.length]!;
    const personSeed = 20 + (this.#nextPerson % NEW_PEOPLE.length);
    this.#nextPerson += 1;
    const peer = `demo-peer-${++this.#nextPeer}`;
    this.requests = [...this.requests, { id: peer, displayName: person.name, state: { kind: "waiting" } }];
    this.#later(
      DemoTiming.acceptMs,
      () => {
        if (failure) {
          this.updateRequest(peer, (r) => ({ ...r, state: { kind: "failed", failure } }));
          this.changed();
          return;
        }
        this.updateRequest(peer, (r) => ({ ...r, state: { kind: "connecting" } }));
        this.changed();
        this.#later(
          DemoTiming.connectMs,
          () => {
            if (!this.requests.some((r) => r.id === peer)) return;
            const identityKey = identityFromSeed(seed(personSeed)).publicKey;
            const id = contactIDFor(identityKey);
            if (!this.contact(id)) {
              this.contacts = [
                ...this.contacts,
                { id, displayName: person.name, identityKey, addedAt: this.now(), isBlocked: false, isVerified: false },
              ];
              this.conversations.set(id, { messages: [], unreadCount: 0 });
            }
            this.updateRequest(peer, (r) => ({ ...r, state: { kind: "connected", contactID: id } }));
            this.#connected(id);
            this.#later(DemoTiming.greetingMs, () => this.#receive(id, person.greeting));
          },
          peer,
        );
      },
      peer,
    );
    return { kind: "started", peer, contactID: null };
  }

  /** An incoming message from a connected contact. */
  #receive(id: ContactID, text: string): void {
    if (this.#links.get(id) !== "connected") return;
    const message: Message = {
      id: demoUUID(1000 + this.#nextMessage++),
      direction: "incoming",
      text,
      timestamp: this.now(),
      status: "delivered",
    };
    this.appendMessage(id, message, this.activeConversation !== id);
    this.emit({ kind: "messageReceived", contactID: id, message });
    this.changed();
  }

  dismiss(request: PeerToken): void {
    const existing = this.requests.find((r) => r.id === request);
    if (!existing) return;
    if (existing.state.kind === "waiting" || existing.state.kind === "connecting") {
      for (const timer of this.#requestTimers.get(request) ?? []) {
        clearTimeout(timer);
        this.#timers.delete(timer);
      }
    }
    this.#requestTimers.delete(request);
    this.requests = this.requests.filter((r) => r.id !== request);
    this.changed();
  }

  disconnect(id: ContactID): void {
    if (!this.contact(id)) return;
    this.#links.set(id, "outOfRange");
    this.parkUnconfirmedMessages(id);
    this.changed();
  }

  async eraseEverything(): Promise<void> {
    for (const timer of this.#timers) clearTimeout(timer);
    this.#timers.clear();
    this.#requestTimers.clear();
    this.#outcomes = [];
    this.#seed("firstRun");
    this.changed();
  }

  /** Which scenario this demo started from. */
  get scenario(): DemoScenario {
    return this.#scenario;
  }
}
