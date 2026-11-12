/**
 * One conversation: header with link state, a banner when the phone is not connected,
 * the messages, and the composer.
 */
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Limits, type ContactID, type ConversationSummary, type Message } from "../engine/api";
import { useAnnounce } from "./announcer";
import { Avatar } from "./Avatar";
import { firstName, formatDaySeparator, formatTime, linkLabel, sameGroup, startOfDay } from "./format";
import { AlertIcon, ArrowDownIcon, BackIcon, ClockIcon, InfoIcon, LockIcon, RetryIcon, SealIcon, SendIcon, TrashIcon, UnlinkIcon } from "./Icons";
import { Rings } from "./Rings";
import { useEngine, useSnapshot } from "./store";

/** Unsent text per conversation, kept in memory only while the tab is open. */
const drafts = new Map<ContactID, string>();
const COUNTER_FROM = Limits.maxMessageLength - 200;

const prefersReducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const hasFinePointer = () => window.matchMedia("(pointer: fine)").matches;

export function ChatView({ summary, onBack, onDetails, onFind }: {
  summary: ConversationSummary;
  onBack: () => void;
  onDetails: () => void;
  onFind: () => void;
}) {
  const engine = useEngine();
  const snapshot = useSnapshot();
  const { contact, link } = summary;
  const id = contact.id;
  // The engine hands out a fresh list after every change, so re-read it with each snapshot.
  const messages = useMemo(() => engine.messages(id), [engine, id, snapshot]);
  const announce = useAnnounce();
  const first = firstName(contact.displayName);

  const disconnect = () => {
    engine.disconnect(id);
    announce(`Disconnected from ${contact.displayName}. New messages will wait until you reconnect.`);
  };

  return (
    <section className="chat" aria-labelledby={`chat-title-${id}`}>
      <header className="pane-head chat__head">
        <button type="button" className="icon-button only-narrow" onClick={onBack} aria-label="Back to conversations">
          <BackIcon />
        </button>
        <button type="button" className="chat__who" onClick={onDetails}>
          <Avatar name={contact.displayName} link={contact.isBlocked ? undefined : link} size={38} />
          <span className="chat__who-text">
            <span className="chat__name" id={`chat-title-${id}`}>
              {contact.displayName}
              {contact.isVerified && <span className="seal" title="Verified"><SealIcon size={17} /></span>}
            </span>
            <span className="link-label" data-link={contact.isBlocked ? "outOfRange" : link}>
              {!contact.isBlocked && link !== "outOfRange" && <span className="link-dot" aria-hidden="true" />}
              {contact.isBlocked ? "Blocked" : linkLabel(link)}
            </span>
          </span>
          <span className="visually-hidden">. Open contact details</span>
        </button>
        <div className="pane-head__actions">
          {link === "connected" && (
            <button type="button" className="pill pill--tinted chat__disconnect" onClick={disconnect} aria-label={`Disconnect from ${contact.displayName}`}>
              <UnlinkIcon size={18} />
              <span className="chat__disconnect-label">Disconnect</span>
            </button>
          )}
          <button type="button" className="icon-button icon-button--accent" onClick={onDetails} aria-label="Contact details" title="Contact details">
            <InfoIcon />
          </button>
        </div>
      </header>

      <LinkBanner summary={summary} onFind={onFind} />

      <MessageList key={`list-${id}`} summary={summary} messages={messages} />

      {contact.isBlocked ? (
        <div className="composer composer--blocked">
          <p>You blocked {first}. Unblock them in contact details to send messages again.</p>
        </div>
      ) : (
        <Composer key={`composer-${id}`} contactID={id} name={contact.displayName} />
      )}
    </section>
  );
}

function LinkBanner({ summary, onFind }: { summary: ConversationSummary; onFind: () => void }) {
  const { isFinding } = useSnapshot();
  const { contact, link } = summary;
  const first = firstName(contact.displayName);
  if (contact.isBlocked || link === "connected") return null;
  if (link === "connecting") {
    return (
      <div className="banner banner--connecting" role="status">
        <Rings animated className="banner__rings" />
        <div className="banner__text">
          <p><strong>Connecting to {first}'s phone…</strong></p>
          <p className="banner__hint">If the link dropped, this can take up to half a minute. Messages you write wait here meanwhile.</p>
        </div>
      </div>
    );
  }
  return (
    <div className="banner">
      <ClockIcon />
      <div className="banner__text">
        <p><strong>Not connected to {first}'s phone.</strong> Messages you write wait here and send when you reconnect.</p>
        <p className="banner__hint">{first} needs Earshot open on their phone, within a room or two of you.</p>
      </div>
      <button type="button" className="pill pill--filled banner__action" onClick={onFind} disabled={isFinding}>
        {isFinding ? "Choose in the list…" : "Reconnect"}
      </button>
    </div>
  );
}

type Row =
  | { kind: "day"; key: string; label: string }
  | { kind: "message"; key: string; message: Message; first: boolean; last: boolean; showMeta: boolean; showTime: boolean; isLastOutgoing: boolean };

function buildRows(messages: Message[]): Row[] {
  const rows: Row[] = [];
  let lastOutgoingID: string | null = null;
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message?.direction === "outgoing") {
      lastOutgoingID = message.id;
      break;
    }
  }
  messages.forEach((message, index) => {
    const previous = messages[index - 1];
    const next = messages[index + 1];
    const newDay = !previous || startOfDay(previous.timestamp) !== startOfDay(message.timestamp);
    const longGap = previous && message.timestamp - previous.timestamp > 60 * 60_000;
    if (newDay || longGap) rows.push({ kind: "day", key: `day-${message.id}`, label: formatDaySeparator(message.timestamp) });
    const first = !previous || newDay || Boolean(longGap) || !sameGroup(previous, message);
    const last = !next || !sameGroup(message, next) || next.timestamp - message.timestamp > 60 * 60_000;
    const isLastOutgoing = message.id === lastOutgoingID;
    // Times appear where the conversation pauses (15 minutes or more) and under the newest message;
    // day separators and hover titles cover the rest, so the chat isn't a column of clock times.
    const pauseAfter = !next || next.timestamp - message.timestamp >= 15 * 60_000;
    const showTime = last && pauseAfter;
    const showMeta = showTime || (message.direction === "outgoing" && (message.status !== "delivered" || isLastOutgoing));
    rows.push({ kind: "message", key: message.id, message, first, last, showMeta, showTime, isLastOutgoing });
  });
  return rows;
}

function MessageList({ summary, messages }: { summary: ConversationSummary; messages: Message[] }) {
  const { contact } = summary;
  const scroller = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);
  const seen = useRef(messages.length);
  const [unseen, setUnseen] = useState(0);
  const announce = useAnnounce();
  const rows = useMemo(() => buildRows(messages), [messages]);

  const scrollToBottom = useCallback((smooth: boolean) => {
    const element = scroller.current;
    if (!element) return;
    element.scrollTo({ top: element.scrollHeight, behavior: smooth && !prefersReducedMotion() ? "smooth" : "auto" });
    atBottom.current = true;
    setUnseen(0);
  }, []);

  // Open at the newest message.
  useLayoutEffect(() => {
    scrollToBottom(false);
  }, [scrollToBottom]);

  // New messages: follow along only if the reader is already at the bottom, or just sent one.
  useLayoutEffect(() => {
    const added = messages.slice(seen.current);
    seen.current = messages.length;
    if (added.length === 0) {
      // Status changes (for example "Sending…" to "Delivered") can change heights; stay pinned.
      if (atBottom.current) scrollToBottom(false);
      return;
    }
    const sentByMe = added.some((message) => message.direction === "outgoing");
    if (sentByMe || atBottom.current) {
      scrollToBottom(true);
    } else {
      setUnseen((count) => count + added.filter((message) => message.direction === "incoming").length);
    }
  }, [messages, scrollToBottom]);

  useEffect(() => {
    if (messages.length < seen.current) seen.current = messages.length;
  }, [messages.length]);

  const onScroll = () => {
    const element = scroller.current;
    if (!element) return;
    atBottom.current = element.scrollHeight - element.scrollTop - element.clientHeight < 72;
    if (atBottom.current && unseen) setUnseen(0);
  };

  return (
    <div className="messages-wrap">
      <div className="messages-scroll" ref={scroller} onScroll={onScroll} tabIndex={0} aria-label={`Messages with ${contact.displayName}`}>
        <div className="messages-column">
          <ChatIntro summary={summary} />
          {messages.length === 0 && <p className="messages-empty">No messages yet. Say hello.</p>}
          <ol className="messages" role="list">
            {rows.map((row) =>
              row.kind === "day" ? (
                <li key={row.key} className="day-separator"><span>{row.label}</span></li>
              ) : (
                <MessageItem key={row.key} row={row} contactID={contact.id} name={contact.displayName} announce={announce} />
              ),
            )}
          </ol>
        </div>
      </div>
      {unseen > 0 && (
        <button type="button" className="new-messages" onClick={() => scrollToBottom(true)}>
          <ArrowDownIcon size={18} /> {unseen === 1 ? "1 new message" : `${unseen} new messages`}
        </button>
      )}
    </div>
  );
}

function ChatIntro({ summary }: { summary: ConversationSummary }) {
  const { contact } = summary;
  const first = firstName(contact.displayName);
  return (
    <div className="chat-intro">
      <Avatar name={contact.displayName} size={64} />
      <p className="chat-intro__name">{contact.displayName}</p>
      <p className="chat-intro__note">
        <LockIcon size={16} />
        <span>
          {contact.isVerified ? "Verified in person. " : ""}
          Messages are end-to-end encrypted and stored only in this browser and on {first}'s phone.
        </span>
      </p>
    </div>
  );
}

function MessageItem({ row, contactID, name, announce }: {
  row: Extract<Row, { kind: "message" }>;
  contactID: ContactID;
  name: string;
  announce: (text: string) => void;
}) {
  const engine = useEngine();
  const { message } = row;
  const outgoing = message.direction === "outgoing";
  const first = firstName(name);
  const time = formatTime(message.timestamp);
  return (
    <li
      className="message"
      data-direction={message.direction}
      data-status={outgoing ? message.status : undefined}
      data-first={row.first || undefined}
      data-last={row.last || undefined}
    >
      <div className="bubble" title={new Date(message.timestamp).toLocaleString()}>
        <span className="visually-hidden">{outgoing ? "You" : first}, {time}: </span>
        {message.text}
      </div>
      {row.showMeta && (
        <div className="message__meta">
          {!outgoing && <span>{time}</span>}
          {outgoing && message.status === "delivered" && (
            <span>{row.isLastOutgoing ? (row.showTime ? `Delivered, ${time}` : "Delivered") : time}</span>
          )}
          {outgoing && message.status === "sending" && <span>Sending…</span>}
          {outgoing && message.status === "waiting" && (
            <span className="message__waiting"><ClockIcon size={14} /> Waiting for {first} to connect. Sends by itself.</span>
          )}
          {outgoing && message.status === "failed" && (
            <span className="message__failed">
              <span className="message__failed-label"><AlertIcon size={15} /> Not delivered</span>
              <button
                type="button"
                className="text-button"
                onClick={() => {
                  engine.retry(message.id, contactID);
                  announce("Trying again.");
                }}
              >
                <RetryIcon size={15} /> Try again
              </button>
              <button
                type="button"
                className="text-button text-button--danger"
                onClick={() => {
                  engine.deleteMessage(message.id, contactID);
                  announce("Message deleted.");
                }}
              >
                <TrashIcon size={15} /> Delete
              </button>
            </span>
          )}
        </div>
      )}
    </li>
  );
}

function Composer({ contactID, name }: { contactID: ContactID; name: string }) {
  const engine = useEngine();
  const announce = useAnnounce();
  const [text, setText] = useState(() => drafts.get(contactID) ?? "");
  const [error, setError] = useState<string | null>(null);
  const field = useRef<HTMLTextAreaElement>(null);
  const counterId = useId();
  const errorId = useId();
  const length = text.length;
  const canSend = text.trim().length > 0 && length <= Limits.maxMessageLength;

  useEffect(() => {
    // Put the cursor in the box on computers; on phones that would pop the keyboard over the chat.
    if (hasFinePointer()) field.current?.focus({ preventScroll: true });
  }, []);

  const update = (value: string) => {
    setText(value);
    setError(null);
    if (value) drafts.set(contactID, value);
    else drafts.delete(contactID);
  };

  const send = () => {
    const clean = text.trim();
    if (!clean) return;
    const message = engine.send(clean, contactID);
    if (!message) {
      setError("Couldn't send this message. Check that it isn't empty or longer than 2,000 characters.");
      return;
    }
    update("");
    if (message.status === "waiting") announce(`Saved. It sends when ${firstName(name)} is connected.`);
    field.current?.focus();
  };

  const describedBy = [length >= COUNTER_FROM ? counterId : null, error ? errorId : null].filter(Boolean).join(" ") || undefined;

  return (
    <form
      className="composer"
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <div className="composer__field">
        <label className="visually-hidden" htmlFor={`composer-${contactID}`}>Message {name}</label>
        <textarea
          id={`composer-${contactID}`}
          ref={field}
          className="composer__input"
          rows={1}
          value={text}
          maxLength={Limits.maxMessageLength}
          placeholder={`Message ${firstName(name)}`}
          aria-describedby={describedBy}
          onChange={(event) => update(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              send();
            }
          }}
        />
        {length >= COUNTER_FROM && (
          <span id={counterId} className="composer__counter" data-full={length >= Limits.maxMessageLength || undefined}>
            {Limits.maxMessageLength - length} characters left
          </span>
        )}
      </div>
      <button type="submit" className="send-button" disabled={!canSend} aria-label="Send">
        <SendIcon />
      </button>
      {error && (
        <p id={errorId} className="composer__error" role="alert">{error}</p>
      )}
    </form>
  );
}

