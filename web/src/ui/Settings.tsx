/** Your name, notifications, explanations and "Erase everything". */
import { useId, useState } from "react";
import { Limits } from "../engine/api";
import { useAnnounce } from "./announcer";
import { Avatar } from "./Avatar";
import type { ConfirmRequest } from "./Dialog";
import { graphemes, sanitizeName } from "./format";
import { BackIcon, BellIcon, ChevronRightIcon, LockIcon, TrashIcon, WavesIcon } from "./Icons";
import { askPermission, type Permission } from "./notifications";
import { clearPrefs, setPref, usePref } from "./prefs";
import { useEngine, useSnapshot } from "./store";

export function SettingsPage({ onBack, onHowItWorks, onPrivacy, confirm, permission, setPermission, onErased }: {
  onBack: () => void;
  onHowItWorks: () => void;
  onPrivacy: () => void;
  confirm: (request: ConfirmRequest) => void;
  permission: Permission;
  setPermission: (value: Permission) => void;
  onErased: () => void;
}) {
  const engine = useEngine();
  const { profile } = useSnapshot();
  const announce = useAnnounce();
  const showText = usePref("showText");
  const [name, setName] = useState(profile.displayName);
  const [saved, setSaved] = useState(false);
  const nameId = useId();
  const nameHelpId = useId();
  const clean = sanitizeName(name);
  const canSave = clean.length > 0 && clean !== profile.displayName;

  const saveName = () => {
    if (!canSave) return;
    engine.setDisplayName(clean);
    setName(clean);
    setSaved(true);
    announce(`Name changed to ${clean}.`);
  };

  const erase = () =>
    confirm({
      title: "Erase everything?",
      body: (
        <>
          <p>
            Deletes your name, your identity key, every contact and every message from this browser. It can't be undone,
            and the phones you talked to keep their copies.
          </p>
          <p>Afterwards Earshot starts fresh, and phones will see this browser as someone new.</p>
        </>
      ),
      confirmLabel: "Erase everything",
      destructive: true,
      onConfirm: async () => {
        await engine.eraseEverything();
        clearPrefs();
        onErased();
      },
    });

  return (
    <section className="page" aria-labelledby="settings-title">
      <header className="pane-head">
        <button type="button" className="icon-button" onClick={onBack} aria-label="Back">
          <BackIcon />
        </button>
        <h2 className="pane-head__title" id="settings-title" tabIndex={-1}>Settings</h2>
        <span className="pane-head__spacer" />
      </header>
      <div className="page__scroll">
        <div className="page__column">
          <h3 className="group-title">Your name</h3>
          <form
            className="group name-form"
            onSubmit={(event) => {
              event.preventDefault();
              saveName();
            }}
          >
            <Avatar name={clean || profile.displayName} size={44} />
            <label className="visually-hidden" htmlFor={nameId}>Your name</label>
            <input
              id={nameId}
              className="text-input name-form__input"
              value={name}
              autoComplete="nickname"
              spellCheck={false}
              aria-describedby={nameHelpId}
              onChange={(event) => {
                const value = event.target.value;
                setName(graphemes(value).length > Limits.maxNameLength ? graphemes(value).slice(0, Limits.maxNameLength).join("") : value);
                setSaved(false);
              }}
            />
            <button type="submit" className="pill pill--filled" disabled={!canSave}>
              Save
            </button>
          </form>
          <p className="group-footer" id={nameHelpId}>
            {saved
              ? "Saved. Phones see the new name the next time you connect."
              : "Shown to the phones you connect to. A first name or nickname is plenty. Up to 32 characters."}
          </p>

          <h3 className="group-title">Notifications</h3>
          <div className="group">
            <div className="group__row group__row--static">
              <BellIcon size={20} />
              <span className="group__label">Message alerts</span>
              <NotificationStatus permission={permission} setPermission={setPermission} />
            </div>
            <label className="group__row toggle-row">
              <span className="group__label">Show message text in notifications</span>
              <input
                type="checkbox"
                role="switch"
                className="switch"
                checked={showText}
                onChange={(event) => setPref("showText", event.target.checked)}
              />
            </label>
          </div>
          <p className="group-footer">
            Notifications appear only while this tab is open and you're looking at something else. They say only who wrote,
            "New message", unless you turn on the text. They're made in this browser; nothing goes to a server.
            {permission === "denied" && " To allow them, open the site settings next to the address bar."}
          </p>

          <div className="group">
            <button type="button" className="group__row" onClick={onHowItWorks}>
              <WavesIcon size={20} />
              <span className="group__label">How Earshot works</span>
              <ChevronRightIcon size={18} />
            </button>
            <button type="button" className="group__row" onClick={onPrivacy}>
              <LockIcon size={20} />
              <span className="group__label">Privacy</span>
              <ChevronRightIcon size={18} />
            </button>
          </div>

          <h3 className="group-title">This browser</h3>
          <div className="group">
            <button type="button" className="group__row group__row--danger" onClick={erase}>
              <TrashIcon size={20} />
              <span className="group__label">Erase everything</span>
            </button>
          </div>
          <p className="group-footer">
            Your identity key, contacts and messages are stored only in this browser. Clearing this site's data in the
            browser's settings erases them too.
          </p>
        </div>
      </div>
    </section>
  );
}

function NotificationStatus({ permission, setPermission }: { permission: Permission; setPermission: (value: Permission) => void }) {
  if (permission === "unsupported") return <span className="group__value">Not available in this browser</span>;
  if (permission === "granted") return <span className="group__value">On</span>;
  if (permission === "denied") return <span className="group__value">Blocked by the browser</span>;
  return (
    <button
      type="button"
      className="pill pill--tinted"
      onClick={async () => {
        const result = await askPermission();
        setPermission(result);
        setPref("offerAnswered", true);
      }}
    >
      Turn on
    </button>
  );
}
