import { expect, openDemo, row, test } from "./fixtures";

test("populated list shows names, previews, link state and unread counts", async ({ page }) => {
  await openDemo(page, "populated");
  await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();
  const rows = page.locator(".sidebar .row");
  await expect(rows).not.toHaveCount(0);

  const maya = row(page, "Maya Okafor");
  await expect(maya).toContainText("Connected");
  await expect(maya.locator(".row__seal")).toBeVisible();

  const jonas = row(page, "Jonas Weber");
  await expect(jonas).toContainText("Waiting:");
  await expect(jonas).not.toContainText("Connected");

  // The total unread count, and nothing else, goes in the tab title.
  const unread = await page.locator(".sidebar .badge").allTextContents();
  const total = unread.reduce((sum, text) => sum + Number.parseInt(text, 10), 0);
  if (total > 0) await expect(page).toHaveTitle(`(${total}) Earshot`);
  else await expect(page).toHaveTitle("Earshot");
});

test("empty scenario explains how to start", async ({ page }) => {
  await openDemo(page, "empty");
  await expect(page.getByText("No conversations yet")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Nobody to talk to yet" })).toBeVisible();
  await expect(page.getByText(/may appear under a device name/)).toBeVisible();
});
