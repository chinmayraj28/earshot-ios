/**
 * "How Earshot works" and "Privacy" for the web version. Same voice as the phone app, but
 * every fact is rewritten for what a web page can really do.
 */
import type { ReactNode } from "react";
import { BackIcon, BellIcon, ClockIcon, EyeOffIcon, HandIcon, LaptopIcon, LockIcon, PhoneIcon, SealIcon, ShieldIcon, StorageIcon, TabIcon, WavesIcon } from "./Icons";
import { Rings } from "./Rings";

export function Explainer({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <div className="explainer">
      <span className="explainer__icon">{icon}</span>
      <div>
        <h3 className="explainer__title">{title}</h3>
        <p className="explainer__detail">{children}</p>
      </div>
    </div>
  );
}

/** The short version, used during onboarding. */
export function WebLimitsSummary() {
  return (
    <div className="explainers">
      <Explainer icon={<WavesIcon />} title="Bluetooth, straight to their phone">
        No Wi‑Fi, internet or mobile signal. Range is about a room or two, roughly 10 to 30 metres indoors, and less
        through walls.
      </Explainer>
      <Explainer icon={<HandIcon />} title="You always start">
        A web page can't announce itself, so phones can't find this browser. You click "Find a nearby phone", pick their
        phone from the browser's list, and they accept on their phone.
      </Explainer>
      <Explainer icon={<PhoneIcon />} title="Earshot open on their phone">
        Their phone only shows up in the list while Earshot is open on its screen. Once you're connected, it can lock
        and the link stays.
      </Explainer>
      <Explainer icon={<TabIcon />} title="Keep this tab open">
        Closing the tab ends the connection. Later, reconnecting is one click. Messages you write in between wait and
        send when you reconnect.
      </Explainer>
    </div>
  );
}

function RangeDiagram() {
  return (
    <figure className="range-diagram">
      <div className="range-diagram__art" aria-hidden="true">
        <Rings className="range-diagram__rings" dot={0} />
        <span className="range-diagram__node range-diagram__node--you"><LaptopIcon size={26} /><span>This browser</span></span>
        <span className="range-diagram__link" />
        <span className="range-diagram__node range-diagram__node--near"><PhoneIcon size={26} /><span>In range</span></span>
        <span className="range-diagram__node range-diagram__node--far"><PhoneIcon size={26} /><span>Out of range</span></span>
      </div>
      <figcaption className="visually-hidden">
        Diagram: this browser reaches a phone a short distance away. A phone further away is out of range.
      </figcaption>
    </figure>
  );
}

function InfoPage({ title, onBack, children }: { title: string; onBack: () => void; children: ReactNode }) {
  return (
    <section className="page" aria-labelledby="info-title">
      <header className="pane-head">
        <button type="button" className="icon-button" onClick={onBack} aria-label="Back to settings">
          <BackIcon />
        </button>
        <h2 className="pane-head__title" id="info-title" tabIndex={-1}>{title}</h2>
        <span className="pane-head__spacer" />
      </header>
      <div className="page__scroll">
        <div className="page__column page__column--prose">{children}</div>
      </div>
    </section>
  );
}

export function HowItWorksPage({ onBack }: { onBack: () => void }) {
  return (
    <InfoPage title="How Earshot works" onBack={onBack}>
      <RangeDiagram />
      <div className="explainers">
        <Explainer icon={<WavesIcon />} title="Bluetooth, browser to phone">
          Earshot talks straight from this browser to the other person's phone over Bluetooth. It uses no Wi‑Fi,
          internet or mobile signal, and messages aren't passed along through other devices.
        </Explainer>
        <Explainer icon={<ShieldIcon />} title="Short range">
          About a room or two: roughly 10 to 30 metres indoors, more in the open, less through walls and bodies.
        </Explainer>
        <Explainer icon={<HandIcon />} title="You always start the connection">
          A web page can only reach out; it can't announce itself. So phones can't find this browser and nobody can send
          it a request. Click "Find a nearby phone", choose their phone in the browser's list, and the person holding it
          taps Accept.
        </Explainer>
        <Explainer icon={<PhoneIcon />} title="Their phone needs Earshot on screen">
          A phone shows up in the browser's list only while Earshot is open on its screen. The list may show it under a
          device name such as "iPhone" rather than the person's name; their Earshot name appears once you pick it. After
          you're connected, they can lock their phone and the link stays open.
        </Explainer>
        <Explainer icon={<TabIcon />} title="Only while this tab is open">
          Closing the tab or the browser ends the connection, and this page can't receive anything while it's closed.
          When you come back, or after their phone has been out of range for a while, reconnecting to a saved contact is
          one click and one pick in the list.
        </Explainer>
        <Explainer icon={<ClockIcon />} title="Messages that wait">
          If you're not connected, your message shows "Waiting" and sends by itself the next time you reconnect to that
          phone.
        </Explainer>
        <Explainer icon={<SealIcon size={22} filled={false} />} title={"“Delivered” means delivered"}>
          Delivered appears only after the phone confirms it received and saved your message. "Not delivered" means no
          confirmation came back. You can try again or delete it.
        </Explainer>
        <Explainer icon={<LaptopIcon />} title="Which browsers work">
          Chrome, Edge and other Chromium browsers on a computer or an Android phone, on a secure (https) address. Safari,
          Firefox and every browser on iPhone and iPad can't use Bluetooth from a web page; on an iPhone, use the Earshot
          app.
        </Explainer>
      </div>
    </InfoPage>
  );
}

const LIMITS = [
  "Anyone who can use this browser profile can open Earshot and read your messages.",
  "Names aren't unique. Someone new can pick the same name as a person you know, so compare safety codes if it matters.",
  "People with radio equipment can tell that Earshot devices are nearby and talking, and roughly how much.",
  "Browser extensions you've installed may be able to read pages you open, including this one.",
  "The encryption hasn't had an independent security audit.",
];

export function PrivacyPage({ onBack }: { onBack: () => void }) {
  return (
    <InfoPage title="Privacy" onBack={onBack}>
      <p className="lede">
        Earshot has no servers and no accounts. Your messages go from this browser to their phone and nowhere else.
      </p>
      <div className="explainers">
        <Explainer icon={<LockIcon />} title="End-to-end encrypted">
          Every conversation is encrypted with keys that stay in this browser and on the other phone. Compare safety
          codes to be sure nobody was in between when you first connected.
        </Explainer>
        <Explainer icon={<StorageIcon />} title="Stored only in this browser">
          Your messages, contacts and the key that proves who you are are kept in this browser's own storage for this
          site. They aren't synced or uploaded. Clearing this site's data in the browser, or "Erase everything" in
          Settings, deletes them for good.
        </Explainer>
        <Explainer icon={<BellIcon />} title="Notifications stay on this device">
          If you turn them on, notifications are made by this page while it's open. Nothing goes to any server. By
          default they say only who wrote; showing the text is your choice in Settings.
        </Explainer>
        <Explainer icon={<PhoneIcon />} title="What the other phone sees">
          Only the phone you pick and connect to sees the name you chose. Phones nearby can't see this browser at all,
          because a web page can't announce itself.
        </Explainer>
        <Explainer icon={<EyeOffIcon />} title="Nothing else leaves the page">
          No analytics, no tracking, no outside scripts or fonts. After the first visit, Earshot opens without any
          network. Names and messages are never put in the page address.
        </Explainer>
        <Explainer icon={<HandIcon />} title="Few permissions">
          The browser asks you to choose a Bluetooth device each time you find a phone. On Android, it may also ask once
          to let the browser use nearby devices or location, which Android requires for Bluetooth. Notifications are
          asked about only if you click to turn them on. Earshot never reads your location, contacts or camera.
        </Explainer>
      </div>
      <h3 className="limits-title">What Earshot doesn't protect against</h3>
      <ul className="limits">
        {LIMITS.map((limit) => (
          <li key={limit}>{limit}</li>
        ))}
      </ul>
    </InfoPage>
  );
}
