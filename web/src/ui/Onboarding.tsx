/** First run: the promise, how it works on the web, and your name. Three steps. */
import { useEffect, useId, useRef, useState } from "react";
import { Limits } from "../engine/api";
import { graphemes, sanitizeName } from "./format";
import { BackIcon } from "./Icons";
import { WebLimitsSummary } from "./Info";
import { Rings } from "./Rings";
import { useEngine } from "./store";

const STEPS = 3;

export function Onboarding() {
  const engine = useEngine();
  const [step, setStep] = useState(0);
  const [name, setName] = useState("");
  const heading = useRef<HTMLHeadingElement>(null);
  const field = useRef<HTMLInputElement>(null);
  const nameId = useId();
  const helpId = useId();
  const clean = sanitizeName(name);
  const count = graphemes(name).length;
  const first = useRef(true);

  useEffect(() => {
    // Move focus to the new step so keyboard and screen reader users start at its top.
    if (first.current) {
      first.current = false;
      return;
    }
    if (step === 2) field.current?.focus();
    else heading.current?.focus();
  }, [step]);

  const next = () => {
    if (step < STEPS - 1) setStep(step + 1);
    else if (clean) engine.completeOnboarding(clean);
  };

  return (
    <div className="onboarding" data-step={step}>
      <div className="onboarding__art" aria-hidden="true">
        <Rings animated className="onboarding__rings" />
      </div>
      <main className="onboarding__main">
        <div className="onboarding__top">
          {step > 0 ? (
            <button type="button" className="icon-button" onClick={() => setStep(step - 1)} aria-label="Back">
              <BackIcon />
            </button>
          ) : (
            <span className="icon-button-spacer" />
          )}
          <div className="steps" role="img" aria-label={`Step ${step + 1} of ${STEPS}`}>
            {Array.from({ length: STEPS }, (_, index) => (
              <span key={index} className="steps__dot" data-current={index === step || undefined} />
            ))}
          </div>
          <span className="icon-button-spacer" />
        </div>

        <form
          className="onboarding__content"
          onSubmit={(event) => {
            event.preventDefault();
            next();
          }}
        >
          <div className="onboarding__body" key={step}>
            {step === 0 && (
              <div className="welcome">
                <Rings animated className="welcome__rings" />
                <h1 className="welcome__title" ref={heading} tabIndex={-1}>Earshot</h1>
                <p className="welcome__tagline">Text a nearby iPhone when the network is gone.</p>
                <p className="welcome__body">
                  Reach the person next to you on a stalled train, at a packed festival or deep inside a building, with no
                  internet, no mobile signal and no account. They need the Earshot app on their iPhone. Messages are
                  end-to-end encrypted and stay in this browser and on their phone.
                </p>
              </div>
            )}
            {step === 1 && (
              <div>
                <h1 className="step-title" ref={heading} tabIndex={-1}>How Earshot works on the web</h1>
                <WebLimitsSummary />
              </div>
            )}
            {step === 2 && (
              <div>
                <h1 className="step-title" ref={heading} tabIndex={-1}>What should the other person call you?</h1>
                <label className="field-label" htmlFor={nameId}>Your name</label>
                <input
                  id={nameId}
                  ref={field}
                  className="text-input text-input--large"
                  value={name}
                  placeholder="Your name"
                  autoComplete="nickname"
                  autoCapitalize="words"
                  spellCheck={false}
                  aria-describedby={helpId}
                  onChange={(event) => {
                    const value = event.target.value;
                    const characters = graphemes(value);
                    setName(characters.length > Limits.maxNameLength ? characters.slice(0, Limits.maxNameLength).join("") : value);
                  }}
                />
                <div className="field-help" id={helpId}>
                  <span>Shown on the phones you connect to. A first name or nickname is plenty; you can change it later.</span>
                  <span className="field-help__count" aria-label={`${count} of ${Limits.maxNameLength} characters`}>
                    {count}/{Limits.maxNameLength}
                  </span>
                </div>
              </div>
            )}
          </div>

          <div className="onboarding__footer">
            {step === 2 && (
              <p className="onboarding__note">
                Nothing is sent anywhere yet. Your name and a new identity key are saved only in this browser.
              </p>
            )}
            <button type="submit" className="button button--primary button--wide" disabled={step === 2 && !clean}>
              {step === 0 ? "Get started" : step === 1 ? "Continue" : "Start using Earshot"}
            </button>
          </div>
        </form>
      </main>
    </div>
  );
}
