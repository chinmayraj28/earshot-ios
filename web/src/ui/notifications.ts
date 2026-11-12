/**
 * Browser notifications for new messages. They are created by this page on this device;
 * nothing goes to a server (this is not "push"), so they only appear while the tab is open.
 */
import { useEffect, useState } from "react";

export type Permission = NotificationPermission | "unsupported";

export function notificationsSupported(): boolean {
  return typeof window !== "undefined" && "Notification" in window;
}

export function currentPermission(): Permission {
  return notificationsSupported() ? Notification.permission : "unsupported";
}

/** Must be called from a click. Never call this on page load. */
export async function askPermission(): Promise<Permission> {
  if (!notificationsSupported()) return "unsupported";
  try {
    return await Notification.requestPermission();
  } catch {
    return Notification.permission;
  }
}

/** Keeps up with the permission, including changes made in the browser's site settings. */
export function usePermission(): [Permission, (value: Permission) => void] {
  const [permission, setPermission] = useState<Permission>(currentPermission);
  useEffect(() => {
    const refresh = () => setPermission(currentPermission());
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    let status: PermissionStatus | null = null;
    navigator.permissions
      ?.query({ name: "notifications" })
      .then((result) => {
        status = result;
        result.onchange = refresh;
      })
      .catch(() => undefined);
    return () => {
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
      if (status) status.onchange = null;
    };
  }, []);
  return [permission, setPermission];
}

/** Shows one notification. Clicking it brings this tab forward and calls `onOpen`. */
export function showMessageNotification(options: { title: string; body: string; tag: string; onOpen: () => void }): void {
  if (currentPermission() !== "granted") return;
  try {
    const notification = new Notification(options.title, {
      body: options.body,
      tag: options.tag,
      icon: "/icons/icon-192.png",
      silent: false,
    });
    notification.onclick = () => {
      window.focus();
      options.onOpen();
      notification.close();
    };
  } catch {
    // Some Android browsers only allow notifications from a service worker. Without one
    // registered (development), we quietly skip it; the unread count in the title still updates.
    void navigator.serviceWorker?.getRegistration().then((registration) =>
      registration?.showNotification(options.title, { body: options.body, tag: options.tag, icon: "/icons/icon-192.png" }),
    );
  }
}
