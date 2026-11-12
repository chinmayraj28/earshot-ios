/**
 * The left column on wide screens (the whole screen on narrow ones): who you are, the
 * "Find a nearby phone" action with its progress, and the list of conversations.
 */
import type { ConnectionRequest, ConversationSummary, ContactID } from "../engine/api";
import { Avatar } from "./Avatar";
import { firstName, findFailureText, formatListTime, linkLabel, previewText, requestFailureText, type FindFailure } from "./format";
import { AlertIcon, BellIcon, ClockIcon, GearIcon, RetryIcon, SealIcon } from "./Icons";
import { Rings } from "./Rings";
import { useEngine, useSnapshot } from "./store";

export function Wordmark({ as: Tag = "h1" }: { as?: "h1" | "p" }) {
  return (
    <Tag className="wordmark">
      <Rings className="wordmark__rings" />
      <span>Earshot</span>
    </Tag>
  );
}

export function FindButton({ onFind, compact = false }: { onFind: () => void; compact?: boolean }) {
  const { isFinding } = useSnapshot();
  return (
    <button
      type="button"
      className={`find-button ${compact ? "find-button--compact" : ""}`}
      onClick={onFind}
      disabled={isFinding}
      aria-describedby={compact ? undefined : "find-hint"}
      data-finding={isFinding || undefined}
    >
      <Rings animated={isFinding} className="find-button__rings" />
      <span className="find-button__label">{isFinding ? "Choose the phone in the browser's list…" : "Find a nearby phone"}</span>
    </button>
  );
}

/** Progress and outcomes for "Find a nearby phone". Shown under the button. */
export function RequestTray({ onFind, issue, onDismissIssue }: {
  onFind: () => void;
  issue: FindFailure | null;
  onDismissIssue: () => void;
}) {
  const { requests } = useSnapshot();
  const visible = requests.filter((request) => request.state.kind !== "connected");
  if (!issue && visible.length === 0) return null;
  return (
    <div className="tray">
      {issue && <FindIssue reason={issue} onFind={onFind} onDismiss={onDismissIssue} />}
      {visible.map((request) => (
        <RequestCard key={request.id} request={request} onFind={onFind} />
      ))}
    </div>
  );
}

function FindIssue({ reason, onFind, onDismiss }: { reason: FindFailure; onFind: () => void; onDismiss: () => void }) {
  const text = findFailureText(reason);
  return (
    <section className="notice notice--problem" aria-label="Find a nearby phone: problem">
      <AlertIcon />
      <div className="notice__text">
        <p className="notice__title">{text.title}</p>
        <p className="notice__detail">{text.detail}</p>
        <div className="notice__actions">
          <button type="button" className="pill pill--filled" onClick={onFind}>
            <RetryIcon size={18} /> Try again
          </button>
          <button type="button" className="pill pill--plain" onClick={onDismiss}>
            Dismiss
          </button>
        </div>
      </div>
    </section>
  );
}

function RequestCard({ request, onFind }: { request: ConnectionRequest; onFind: () => void }) {
  const engine = useEngine();
  const name = request.displayName;
  const first = firstName(name);
  const { state } = request;
  return (
    <section className="request" data-state={state.kind} aria-label={`Request to ${name}`}>
      <div className="request__visual">
        {state.kind === "failed" ? <Avatar name={name} size={48} /> : (
          <span className="request__pulse">
            <Rings animated className="request__rings" dot={0} />
            <Avatar name={name} size={36} link={state.kind === "connecting" ? "connecting" : undefined} />
          </span>
        )}
      </div>
      <div className="request__text">
        <p className="request__name">{name}</p>
        {state.kind === "waiting" && (
          <>
            <p className="request__status">Waiting for {first} to accept on their phone</p>
            <p className="request__detail">Earshot on their phone shows your name with Accept and Decline. Keep this tab open meanwhile.</p>
          </>
        )}
        {state.kind === "connecting" && (
          <>
            <p className="request__status">{first} accepted. Connecting…</p>
            <p className="request__detail">Setting up an encrypted link between this browser and their phone.</p>
          </>
        )}
        {state.kind === "failed" && <p className="request__status request__status--failed">{requestFailureText(state.failure, name)}</p>}
        <div className="request__actions">
          {state.kind === "failed" ? (
            <>
              <button type="button" className="pill pill--filled" onClick={() => { engine.dismiss(request.id); onFind(); }}>
                <RetryIcon size={18} /> Try again
              </button>
              <button type="button" className="pill pill--plain" onClick={() => engine.dismiss(request.id)}>
                Dismiss
              </button>
            </>
          ) : (
            <button type="button" className="pill pill--tinted" onClick={() => engine.dismiss(request.id)}>
              Cancel request
            </button>
          )}
        </div>
      </div>
    </section>
  );
}

export function NotificationOffer({ onAccept, onDecline }: { onAccept: () => void; onDecline: () => void }) {
  return (
    <section className="notice notice--offer" aria-label="Notifications">
      <BellIcon />
      <div className="notice__text">
        <p className="notice__title">Get told about new messages?</p>
        <p className="notice__detail">
          While this tab is open but out of sight, Earshot can show a notification when a message arrives. It's made in
          this browser; nothing goes to a server.
        </p>
        <div className="notice__actions">
          <button type="button" className="pill pill--filled" onClick={onAccept}>Turn on notifications</button>
          <button type="button" className="pill pill--plain" onClick={onDecline}>Not now</button>
        </div>
      </div>
    </section>
  );
}

export function ConversationList({ conversations, selected, onOpen }: {
  conversations: ConversationSummary[];
  selected: ContactID | null;
  onOpen: (id: ContactID) => void;
}) {
  if (conversations.length === 0) {
    return (
      <div className="list-empty">
        <p className="list-empty__title">No conversations yet</p>
        <p className="list-empty__detail">
          Find a nearby phone and, once the person holding it accepts, your conversation appears here. It's kept only in
          this browser.
        </p>
      </div>
    );
  }
  return (
    <ul className="conversations" role="list">
      {conversations.map((summary) => (
        <li key={summary.contact.id}>
          <ConversationRow summary={summary} selected={summary.contact.id === selected} onOpen={onOpen} />
        </li>
      ))}
    </ul>
  );
}

function ConversationRow({ summary, selected, onOpen }: { summary: ConversationSummary; selected: boolean; onOpen: (id: ContactID) => void }) {
  const { contact, lastMessage, unreadCount, link } = summary;
  const waiting = lastMessage?.direction === "outgoing" && lastMessage.status === "waiting";
  const failed = lastMessage?.direction === "outgoing" && lastMessage.status === "failed";
  return (
    <button
      type="button"
      className="row"
      aria-current={selected ? "true" : undefined}
      data-unread={unreadCount > 0 || undefined}
      onClick={() => onOpen(contact.id)}
    >
      <Avatar name={contact.displayName} link={contact.isBlocked ? undefined : link} />
      <span className="row__body">
        <span className="row__top">
          <span className="row__name">{contact.displayName}</span>
          {contact.isVerified && (
            <span className="row__seal" title="Verified">
              <SealIcon size={16} />
              <span className="visually-hidden">, verified</span>
            </span>
          )}
          {contact.isBlocked ? (
            <span className="tag">Blocked</span>
          ) : (
            link !== "outOfRange" && (
              <span className="link-label" data-link={link}>
                <span className="link-dot" aria-hidden="true" />
                <span className="link-label__text">{linkLabel(link)}</span>
              </span>
            )
          )}
          <span className="row__time">{formatListTime(summary.lastActivity)}</span>
        </span>
        <span className="row__bottom">
          <span className={`row__preview ${failed ? "row__preview--failed" : ""}`}>
            {waiting && <ClockIcon size={15} />}
            {failed && <AlertIcon size={15} />}
            <span className="row__preview-text">{previewText(lastMessage)}</span>
          </span>
          {unreadCount > 0 && (
            <span className="badge">
              {unreadCount > 99 ? "99+" : unreadCount}
              <span className="visually-hidden"> unread</span>
            </span>
          )}
        </span>
      </span>
    </button>
  );
}

export function SidebarHeader({ onSettings, settingsOpen }: { onSettings: () => void; settingsOpen: boolean }) {
  const { profile } = useSnapshot();
  return (
    <header className="sidebar__head">
      <div className="sidebar__brand">
        <Wordmark />
        <p className="sidebar__me">The phone you connect to sees you as <strong>{profile.displayName}</strong></p>
      </div>
      <button type="button" className="icon-button" onClick={onSettings} aria-label="Settings" aria-current={settingsOpen ? "page" : undefined}>
        <GearIcon />
      </button>
    </header>
  );
}

