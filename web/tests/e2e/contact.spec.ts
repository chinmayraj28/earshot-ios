import { composer, expect, openDemo, row, test } from "./fixtures";
import type { Page } from "@playwright/test";

async function openDetails(page: Page, name: string) {
  await row(page, name).click();
  await page.getByRole("button", { name: "Contact details", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Contact" })).toBeFocused();
}

test("safety code and verification", async ({ page }) => {
  await openDemo(page, "populated");
  await openDetails(page, "Jonas Weber");
  await expect(page.locator(".safety__code")).toHaveText(/^\d{3} \d{3} \d{3}$/);
  await expect(page.locator(".safety__state")).toHaveText("Not verified");
  await page.getByRole("button", { name: "Mark as verified" }).click();
  await expect(page.locator(".safety__state")).toHaveText("Verified");
  await page.getByRole("button", { name: "Mark as not verified" }).click();
  await expect(page.locator(".safety__state")).toHaveText("Not verified");
});

test("block asks first, then blocks; unblock works", async ({ page }) => {
  await openDemo(page, "populated");
  await openDetails(page, "Maya Okafor");
  await page.getByRole("button", { name: "Block Maya Okafor" }).click();
  const dialog = page.getByRole("dialog", { name: "Block Maya Okafor?" });
  await expect(dialog).toBeVisible();
  // Cancel keeps things as they were.
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toBeHidden();
  await expect(page.getByRole("button", { name: "Block Maya Okafor" })).toBeVisible();

  await page.getByRole("button", { name: "Block Maya Okafor" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Block Maya" }).click();
  await expect(page.getByRole("button", { name: "Unblock Maya Okafor" })).toBeVisible();
  await expect(row(page, "Maya Okafor")).toContainText("Blocked");

  await page.getByRole("button", { name: "Back to chat" }).click();
  await expect(page.getByText(/You blocked Maya/)).toBeVisible();
  await expect(composer(page)).toHaveCount(0);

  await page.getByRole("button", { name: "Contact details", exact: true }).click();
  await page.getByRole("button", { name: "Unblock Maya Okafor" }).click();
  await page.getByRole("button", { name: "Back to chat" }).click();
  await expect(composer(page)).toBeVisible();
});

test("Escape closes a confirmation without doing anything", async ({ page }) => {
  await openDemo(page, "populated");
  await openDetails(page, "Maya Okafor");
  await page.getByRole("button", { name: "Remove contact" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toBeHidden();
  await expect(row(page, "Maya Okafor")).toBeVisible();
});

test("clear conversation asks first, then empties the chat", async ({ page }) => {
  await openDemo(page, "populated");
  await openDetails(page, "Maya Okafor");
  await page.getByRole("button", { name: "Clear conversation" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Clear conversation" }).click();
  await page.getByRole("button", { name: "Back to chat" }).click();
  await expect(page.locator(".message")).toHaveCount(0);
  await expect(page.getByText("No messages yet. Say hello.").first()).toBeVisible();
});

test("remove contact asks first, then removes it and returns to the list", async ({ page }) => {
  await openDemo(page, "populated");
  await openDetails(page, "Maya Okafor");
  await page.getByRole("button", { name: "Remove contact" }).click();
  const dialog = page.getByRole("dialog", { name: "Remove Maya Okafor?" });
  await expect(dialog).toContainText("Deletes Maya Okafor and your conversation from this browser.");
  await dialog.getByRole("button", { name: "Remove contact" }).click();
  await expect(row(page, "Maya Okafor")).toHaveCount(0);
  await expect(page.locator(".chat")).toHaveCount(0);
});
