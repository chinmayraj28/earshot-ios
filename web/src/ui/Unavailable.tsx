/** Full-page explanations for when this browser can't use Bluetooth. */
import type { Availability } from "../engine/api";
import { Rings } from "./Rings";
import { Wordmark } from "./Sidebar";

const COPY: Record<Exclude<Availability, "ready">, { title: string; body: string[]; steps: string[] }> = {
  unsupported: {
    title: "This browser can't use Bluetooth",
    body: [
      "Earshot on the web talks to the other person's phone over Bluetooth. Only Chrome, Edge and other Chromium browsers let a web page do that, on a computer or an Android phone.",
      "Safari, Firefox and every browser on iPhone and iPad can't use Bluetooth from a web page.",
    ],
    steps: [
      "On a computer or an Android phone, open this page in Chrome or Edge.",
      "On an iPhone, use the Earshot app instead.",
    ],
  },
  insecure: {
    title: "This page needs a secure address",
    body: [
      "Browsers only allow Bluetooth on pages opened over https, or from localhost on your own computer. This copy of Earshot was opened from an address that isn't secure, so the browser blocks Bluetooth.",
    ],
    steps: ["Open Earshot from its https address.", "If you're running it yourself, open it at http://localhost instead of a network address."],
  },
  bluetoothOff: {
    title: "Bluetooth is off",
    body: ["Earshot needs Bluetooth to reach the phone next to you, and this device's Bluetooth is turned off or missing."],
    steps: [
      "Turn on Bluetooth in this computer's or phone's settings.",
      "Then check again here.",
    ],
  },
};

export function Unavailable({ availability, onContinue }: { availability: Exclude<Availability, "ready">; onContinue?: () => void }) {
  const copy = COPY[availability];
  return (
    <div className="unavailable" data-availability={availability}>
      <main className="unavailable__card">
        <Wordmark as="p" />
        <Rings className="unavailable__rings" />
        <h1 className="unavailable__title">{copy.title}</h1>
        {copy.body.map((paragraph) => (
          <p key={paragraph} className="unavailable__body">{paragraph}</p>
        ))}
        <h2 className="unavailable__subtitle">What to do</h2>
        <ul className="unavailable__steps checklist">
          {copy.steps.map((step) => (
            <li key={step}>{step}</li>
          ))}
        </ul>
        {availability === "bluetoothOff" && (
          <div className="unavailable__actions">
            <button type="button" className="button button--primary" onClick={() => window.location.reload()}>
              Check again
            </button>
            {onContinue && (
              <button type="button" className="button button--quiet" onClick={onContinue}>
                Read saved messages
              </button>
            )}
          </div>
        )}
        <p className="unavailable__footnote">No internet, no servers, no account. Nothing on this page was sent anywhere.</p>
      </main>
    </div>
  );
}
