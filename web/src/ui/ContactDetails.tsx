/** Safety code, verification, disconnect, clear, block and remove for one contact. */
import type { ConversationSummary } from "../engine/api";
import { useAnnounce } from "./announcer";
import { Avatar } from "./Avatar";
import type { ConfirmRequest } from "./Dialog";
import { firstName, formatLongDate, linkLabel } from "./format";
import { BackIcon, BlockIcon, SealIcon, TrashIcon, UnlinkIcon } from "./Icons";
import { useEngine } from "./store";

export function ContactDetails({ summary, onBack, onRemoved, confirm }: {
  summary: ConversationSummary;
  onBack: () => void;
  onRemoved: () => void;
  confirm: (request: ConfirmRequest) => void;
}) {
  const engine = useEngine();
  const announce = useAnnounce();
  const { contact, link } = summary;
  const name = contact.displayName;
  const first = firstName(name);
  const code = engine.safetyCode(contact.id);

  const clear = () =>
    confirm({
      title: `Clear conversation with ${name}?`,
      body: <p>Deletes every message with {name} from this browser. {first} keeps their copy on their phone.</p>,
      confirmLabel: "Clear conversation",
      destructive: true,
      onConfirm: () => {
        engine.clearConversation(contact.id);
        announce("Conversation cleared.");
      },
    });

  const block = () =>
    confirm({
      title: `Block ${name}?`,
      body: (
        <p>
          {first}'s phone won't be able to link to this browser or send you messages, and they won't be told. Messages
          already here stay until you clear them. You can unblock {first} here at any time.
        </p>
      ),
      confirmLabel: `Block ${first}`,
      destructive: true,
      onConfirm: () => {
        engine.setBlocked(true, contact.id);
        announce(`${name} is blocked.`);
      },
    });

  const remove = () =>
    confirm({
      title: `Remove ${name}?`,
      body: (
        <p>
          Deletes {name} and your conversation from this browser. To talk again, find their phone and {first} accepts a
          new request.
        </p>
      ),
      confirmLabel: "Remove contact",
      destructive: true,
      onConfirm: () => {
        engine.removeContact(contact.id);
        announce(`${name} was removed.`);
        onRemoved();
      },
    });

  return (
    <section className="page" aria-labelledby="contact-title">
      <header className="pane-head">
        <button type="button" className="icon-button" onClick={onBack} aria-label="Back to chat">
          <BackIcon />
        </button>
        <h2 className="pane-head__title" id="contact-title" tabIndex={-1}>Contact</h2>
        <span className="pane-head__spacer" />
      </header>
      <div className="page__scroll">
        <div className="page__column">
          <div className="profile">
            <Avatar name={name} link={contact.isBlocked ? undefined : link} size={96} />
            <p className="profile__name">{name}</p>
            <p className="link-label profile__link" data-link={contact.isBlocked ? "outOfRange" : link}>
              {!contact.isBlocked && link !== "outOfRange" && <span className="link-dot" aria-hidden="true" />}
              {contact.isBlocked ? "Blocked" : linkLabel(link)}
            </p>
            <p className="profile__since">Contact since {formatLongDate(contact.addedAt)}</p>
          </div>

          <h3 className="group-title" id="safety-title">Safety code</h3>
          <div className="group" aria-labelledby="safety-title">
            <div className="safety">
              <p className="safety__code">
                {code ?? "Not available"}
              </p>
              {contact.isVerified ? (
                <span className="safety__state safety__state--verified"><SealIcon size={20} /> Verified</span>
              ) : (
                <span className="safety__state">Not verified</span>
              )}
            </div>
            <button
              type="button"
              className="group__row group__row--accent"
              onClick={() => {
                engine.setVerified(!contact.isVerified, contact.id);
                announce(contact.isVerified ? `${name} marked as not verified.` : `${name} marked as verified.`);
              }}
            >
              <SealIcon size={20} filled={false} />
              {contact.isVerified ? "Mark as not verified" : "Mark as verified"}
            </button>
          </div>
          <p className="group-footer">
            When you're together, open {first}'s phone and check that Earshot shows the same number for you. If it
            matches, your messages can only be read by the two of you. The code changes if {first} reinstalls Earshot or
            this browser's data is erased.
          </p>

          <div className="group">
            {link === "connected" && (
              <button
                type="button"
                className="group__row"
                onClick={() => {
                  engine.disconnect(contact.id);
                  announce(`Disconnected from ${name}.`);
                }}
              >
                <UnlinkIcon size={20} /> Disconnect
              </button>
            )}
            <button type="button" className="group__row" onClick={clear}>
              <TrashIcon size={20} /> Clear conversation
            </button>
            {contact.isBlocked ? (
              <button
                type="button"
                className="group__row group__row--accent"
                onClick={() => {
                  engine.setBlocked(false, contact.id);
                  announce(`${name} is unblocked.`);
                }}
              >
                <BlockIcon size={20} /> Unblock {name}
              </button>
            ) : (
              <button type="button" className="group__row group__row--danger" onClick={block}>
                <BlockIcon size={20} /> Block {name}
              </button>
            )}
            <button type="button" className="group__row group__row--danger" onClick={remove}>
              <TrashIcon size={20} /> Remove contact
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
