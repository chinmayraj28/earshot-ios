import { expect, openDemo, test } from "./fixtures";

/** Replaces the browser's Notification with a recorder, so tests can see what would be shown. */
test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const record = { requested: 0, shown: [] as Array<{ title: string; body: string }> };
    (window as unknown as { __notifications: typeof record }).__notifications = record;
    class FakeNotification {
      static permission: NotificationPermission = "default";
      static async requestPermission() {
        record.requested += 1;
        FakeNotification.permission = "granted";
        return "granted" as const;
      }
      onclick: (() => void) | null = null;
      constructor(title: string, options?: NotificationOptions) {
        record.shown.push({ title, body: options?.body ?? "" });
      }
      close() {}
    }
    Object.defineProperty(window, "Notification", { value: FakeNotification, configurable: true });
  });
});

const record = (page: import("@playwright/test").Page) =>
  page.evaluate(() => (window as unknown as { __notifications: { requested: number; shown: Array<{ title: string; body: string }> } }).__notifications);

test("never asks on load; offers after the first contact connects; asks only on click", async ({ page }) => {
  await openDemo(page, "empty");
  await expect(page.getByText("Get told about new messages?")).toHaveCount(0);
  expect((await record(page)).requested).toBe(0);

  await page.getByRole("button", { name: "Find a nearby phone" }).click();
  await expect(page.locator(".chat__name")).toBeVisible({ timeout: 10_000 });
  const offer = page.getByText("Get told about new messages?");
  await expect(offer).toBeVisible();
  expect((await record(page)).requested).toBe(0);

  await page.getByRole("button", { name: "Turn on notifications" }).click();
  await expect(offer).toHaveCount(0);
  expect((await record(page)).requested).toBe(1);
});

test("a message for a chat that isn't open shows a private notification", async ({ page }) => {
  await openDemo(page, "populated");
  await page.evaluate(() => {
    (window.Notification as unknown as { permission: string }).permission = "granted";
  });
  // A new demo contact connects and sends a greeting about 1.5 s later; by then we are in Jensen's chat.
  await page.getByRole("button", { name: "Find a nearby phone" }).click();
  await expect(page.locator(".chat__name")).toBeVisible({ timeout: 10_000 });
  const newName = (await page.locator(".chat__name").textContent())?.trim() ?? "";
  await page.locator(".sidebar .row", { hasText: "Jensen Huang" }).click();
  await expect.poll(async () => (await record(page)).shown.length, { timeout: 10_000 }).toBeGreaterThan(0);
  const shown = (await record(page)).shown[0];
  expect(shown?.title).toBe(newName);
  expect(shown?.body).toBe("New message");
  // The unread count reaches the tab title.
  await expect(page).toHaveTitle(/^\(\d+\) Earshot$/);
});
