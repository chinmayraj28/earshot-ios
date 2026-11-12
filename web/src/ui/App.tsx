/**
 * The app frame: starts the engine, then shows the right top-level screen
 * (browser can't use Bluetooth / first run / the messenger itself).
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ConnectionRequest, ContactID, Engine, EngineEvent } from "../engine/api";
import { AnnouncerProvider, useAnnounce } from "./announcer";
import { Avatar } from "./Avatar";
import { ChatView } from "./Chat";
import { ContactDetails } from "./ContactDetails";
import { ConfirmDialog, type ConfirmRequest } from "./Dialog";
import { chooseEngine } from "./engineChoice";
import { findFailureText, firstName, requestFailureText, type FindFailure } from "./format";
import { HowItWorksPage, PrivacyPage } from "./Info";
import { useNavigation, type View } from "./nav";
import { askPermission, notificationsSupported, showMessageNotification, usePermission } from "./notifications";
import { Onboarding } from "./Onboarding";
import { getPref, setPref, usePref } from "./prefs";
import { Rings } from "./Rings";
import { SettingsPage } from "./Settings";
import { ConversationList, FindButton, NotificationOffer, RequestTray, SidebarHeader } from "./Sidebar";
import { EngineProvider, useEngine, useSnapshot } from "./store";
import { Unavailable } from "./Unavailable";

export function App() {
  const [engine, setEngine] = useState<Engine | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    chooseEngine()
      .then(async (created) => {
        await created.ready();
        if (!cancelled) setEngine(created);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (failed) return <StartFailure />;
  if (!engine) return <Loading />;
  return (
    <EngineProvider engine={engine}>
      <AnnouncerProvider>
        <Root />
      </AnnouncerProvider>
    </EngineProvider>
  );
}

function Loading() {
  return (
    <div className="loading" role="status">
      <Rings animated className="loading__rings" />
      <span className="visually-hidden">Opening Earshot…</span>
    </div>
  );
}

function StartFailure() {
  return (
    <div className="unavailable">
      <main className="unavailable__card">
        <Rings className="unavailable__rings" />
        <h1 className="unavailable__title">Earshot couldn't start</h1>
        <p className="unavailable__body">
          It couldn't open its storage in this browser. This can happen in a private window or when the browser is set
          to block site data. Allow site data for this page, or open it in a normal window, then reload.
        </p>
        <div className="unavailable__actions">
          <button type="button" className="button button--primary" onClick={() => window.location.reload()}>
            Reload
          </button>
        </div>
      </main>
    </div>
  );
}

function Root() {
  const snapshot = useSnapshot();
  const [readOffline, setReadOffline] = useState(false);
  const { availability, profile } = snapshot;
  if (availability !== "ready" && !(availability === "bluetoothOff" && readOffline)) {
    const canRead = availability === "bluetoothOff" && profile.hasCompletedOnboarding && snapshot.conversations.length > 0;
    return <Unavailable availability={availability} onContinue={canRead ? () => setReadOffline(true) : undefined} />;
  }
  if (!profile.hasCompletedOnboarding) return <Onboarding />;
  return <Shell />;
}

function Shell() {
  const engine = useEngine();
  const snapshot = useSnapshot();
  const announce = useAnnounce();
  const { view, navigate, back, home } = useNavigation();
  const [confirmRequest, setConfirmRequest] = useState<ConfirmRequest | null>(null);
  const [findIssue, setFindIssue] = useState<FindFailure | null>(null);
  const [permission, setPermission] = usePermission();
  const hasConnected = usePref("hasConnected");
  const offerAnswered = usePref("offerAnswered");
  const [visible, setVisible] = useState(() => !document.hidden);
  const mainRef = useRef<HTMLElement>(null);

  const viewRef = useRef<View>(view);
  viewRef.current = view;

  const summaryFor = useCallback(
    (id: ContactID) => snapshot.conversations.find((summary) => summary.contact.id === id) ?? null,
    [snapshot.conversations],
  );

  // Leave screens whose contact no longer exists (removed, or everything erased).
  const viewContact = view.kind === "chat" || view.kind === "contact" ? view.id : null;
  const contactMissing = viewContact !== null && !summaryFor(viewContact);
  useEffect(() => {
    if (contactMissing) navigate({ kind: "home" }, { replace: true });
  }, [contactMissing, navigate]);

  // Tell the engine which chat is really on screen, so those messages don't count as unread.
  useEffect(() => {
    const onVisibility = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, []);
  const activeChat = view.kind === "chat" ? view.id : null;
  useEffect(() => {
    engine.setActiveConversation(visible ? activeChat : null);
  }, [engine, visible, activeChat]);
  useEffect(() => () => engine.setActiveConversation(null), [engine]);

  // Unread count in the tab title, and nothing else (no names, no text).
  const unread = snapshot.conversations.reduce((total, summary) => total + summary.unreadCount, 0);
  useEffect(() => {
    document.title = unread > 0 ? `(${unread}) Earshot` : "Earshot";
  }, [unread]);

  const openChat = useCallback(
    (id: ContactID) => {
      const current = viewRef.current;
      // Switching between chats replaces the history entry so Back returns to the list, not the previous chat.
      navigate({ kind: "chat", id }, { replace: current.kind === "chat" });
    },
    [navigate],
  );

  // Messages and connections from the engine: announcements and notifications.
  const handleEvent = useCallback(
    (event: EngineEvent) => {
      const contact = engine.getSnapshot().contacts.find((candidate) => candidate.id === event.contactID);
      if (!contact) return;
      if (event.kind === "connected") {
        announce(`Connected to ${contact.displayName}.`);
        return;
      }
      const current = viewRef.current;
      const isOpen = current.kind === "chat" && current.id === event.contactID;
      if (isOpen && !document.hidden) announce(`${contact.displayName}: ${event.message.text}`);
      else announce(`New message from ${contact.displayName}.`);
      if (document.hidden || !isOpen) {
        showMessageNotification({
          title: contact.displayName,
          body: getPref("showText") ? event.message.text : "New message",
          tag: contact.id,
          onOpen: () => openChat(contact.id),
        });
      }
    },
    [engine, announce, openChat],
  );

  useEffect(
    () =>
      engine.onEvent((event) => {
        if (event.kind === "connected") setPref("hasConnected", true);
        // The engine may fire an event just before it publishes the snapshot that contains the
        // new contact, so look the contact up once the current task has finished.
        queueMicrotask(() => handleEvent(event));
      }),
    [engine, handleEvent],
  );

  // A notification clicked on Android arrives through the service worker.
  useEffect(() => {
    const worker = navigator.serviceWorker;
    if (!worker) return;
    const onMessage = (event: MessageEvent) => {
      const data = event.data as { type?: string; tag?: string } | null;
      if (data?.type === "open-chat" && data.tag) openChat(data.tag);
    };
    worker.addEventListener("message", onMessage);
    return () => worker.removeEventListener("message", onMessage);
  }, [openChat]);

  // Follow connection requests: announce each change, open the chat once connected.
  const lastStates = useRef(new Map<string, ConnectionRequest["state"]["kind"]>());
  useEffect(() => {
    for (const request of snapshot.requests) {
      const previous = lastStates.current.get(request.id);
      if (previous === request.state.kind) continue;
      lastStates.current.set(request.id, request.state.kind);
      const first = firstName(request.displayName);
      switch (request.state.kind) {
        case "waiting":
          announce(`Waiting for ${first} to accept on their phone.`);
          break;
        case "connecting":
          announce(`${first} accepted. Connecting.`);
          break;
        case "failed":
          announce(requestFailureText(request.state.failure, request.displayName));
          break;
        case "connected":
          openChat(request.state.contactID);
          engine.dismiss(request.id);
          break;
      }
    }
  }, [snapshot.requests, announce, engine, openChat]);

  /** Must run straight from a click: the browser only opens its device chooser for a user gesture. */
  const find = useCallback(() => {
    setFindIssue(null);
    engine
      .findNearby()
      .then((result) => {
        if (result.kind === "failed") {
          setFindIssue(result.reason);
          announce(findFailureText(result.reason).title);
        } else if (result.kind === "started" && result.contactID) {
          openChat(result.contactID);
        }
      })
      .catch(() => {
        setFindIssue("unavailable");
        announce(findFailureText("unavailable").title);
      });
  }, [engine, announce, openChat]);

  // Move focus to the new screen's heading (or the composer in a chat) for keyboard users.
  const firstRender = useRef(true);
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    if (view.kind === "chat" || view.kind === "home") return;
    const heading = mainRef.current?.querySelector<HTMLElement>("h2[tabindex='-1']");
    heading?.focus({ preventScroll: true });
  }, [view]);

  const showOffer = notificationsSupported() && permission === "default" && hasConnected && !offerAnswered;
  const tray = <RequestTray onFind={find} issue={findIssue} onDismissIssue={() => setFindIssue(null)} />;

  const detail = useMemo(() => {
    switch (view.kind) {
      case "home":
        return <EmptyPane hasConversations={snapshot.conversations.length > 0} requests={snapshot.requests} />;
      case "chat": {
        const summary = summaryFor(view.id);
        return summary ? (
          <ChatView
            summary={summary}
            onBack={() => back()}
            onDetails={() => navigate({ kind: "contact", id: view.id })}
            onFind={find}
          />
        ) : null;
      }
      case "contact": {
        const summary = summaryFor(view.id);
        return summary ? (
          <ContactDetails
            summary={summary}
            onBack={() => back({ kind: "chat", id: view.id })}
            onRemoved={home}
            confirm={setConfirmRequest}
          />
        ) : null;
      }
      case "settings":
        return (
          <SettingsPage
            onBack={() => back()}
            onHowItWorks={() => navigate({ kind: "howItWorks" })}
            onPrivacy={() => navigate({ kind: "privacy" })}
            confirm={setConfirmRequest}
            permission={permission}
            setPermission={setPermission}
            onErased={home}
          />
        );
      case "howItWorks":
        return <HowItWorksPage onBack={() => back({ kind: "settings" })} />;
      case "privacy":
        return <PrivacyPage onBack={() => back({ kind: "settings" })} />;
    }
  }, [view, snapshot.conversations.length, snapshot.requests, summaryFor, back, navigate, find, home, permission, setPermission]);

  return (
    <div className="shell" data-pane={view.kind === "home" ? "list" : "detail"}>
      {view.kind === "home" ? (
        <a className="skip-link" href="#conversation-list">Skip to conversations</a>
      ) : (
        <a className="skip-link" href="#main">Skip to {view.kind === "chat" ? "conversation" : "main content"}</a>
      )}
      <aside className="sidebar" aria-label="Conversations">
        <SidebarHeader
          onSettings={() => navigate({ kind: "settings" })}
          settingsOpen={view.kind === "settings" || view.kind === "howItWorks" || view.kind === "privacy"}
        />
        <div className="find">
          <FindButton onFind={find} />
          <p className="find__hint" id="find-hint">
            Their phone needs Earshot open on its screen. In the browser's list it may appear under a device name like
            "iPhone"; their Earshot name shows up after you pick it.
          </p>
          {tray}
        </div>
        {showOffer && (
          <NotificationOffer
            onAccept={async () => {
              const result = await askPermission();
              setPermission(result);
              setPref("offerAnswered", true);
              announce(result === "granted" ? "Notifications are on." : "Notifications stay off.");
            }}
            onDecline={() => setPref("offerAnswered", true)}
          />
        )}
        <h2 className="list-title" id="conversation-list" tabIndex={-1}>Conversations</h2>
        <ConversationList conversations={snapshot.conversations} selected={activeChat} onOpen={openChat} />
      </aside>
      <main className="main" id="main" ref={mainRef} tabIndex={-1}>
        {view.kind !== "home" && <div className="floating-tray only-narrow">{tray}</div>}
        {detail}
      </main>
      <ConfirmDialog request={confirmRequest} onClose={() => setConfirmRequest(null)} />
    </div>
  );
}

function EmptyPane({ hasConversations, requests }: { hasConversations: boolean; requests: ConnectionRequest[] }) {
  const pending = requests.find((request) => request.state.kind === "waiting" || request.state.kind === "connecting");
  if (pending) {
    const first = firstName(pending.displayName);
    // A large picture of the request in progress. The words and buttons screen readers use are
    // in the request card in the sidebar, so this copy is hidden from them to avoid repeating it.
    return (
      <div className="empty-pane" aria-hidden="true">
        <div className="pending">
          <div className="pending__visual">
            <Rings animated className="pending__rings" dot={0} />
            <Avatar name={pending.displayName} size={88} link={pending.state.kind === "connecting" ? "connecting" : undefined} />
          </div>
          <p className="pending__title">
            {pending.state.kind === "waiting" ? `Waiting for ${first} to accept on their phone` : `${first} accepted. Connecting…`}
          </p>
          <p className="pending__detail">
            {pending.state.kind === "waiting"
              ? "Earshot on their phone shows your name with Accept and Decline."
              : "Setting up an encrypted link between this browser and their phone."}
          </p>
        </div>
      </div>
    );
  }
  return (
    <div className="empty-pane">
      <Rings className="empty-pane__rings" />
      {hasConversations ? (
        <>
          <h2 className="empty-pane__title">Pick a conversation</h2>
          <p className="empty-pane__detail">Or find a nearby phone to start a new one.</p>
        </>
      ) : (
        <>
          <h2 className="empty-pane__title">Nobody to talk to yet</h2>
          <p className="empty-pane__detail">To find someone, you need:</p>
          <ul className="checklist">
            <li>Bluetooth on, here and on their iPhone</li>
            <li>To be within a room or two of each other</li>
            <li>Earshot open on their phone's screen</li>
          </ul>
        </>
      )}
    </div>
  );
}
