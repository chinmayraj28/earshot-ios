import { expect, openDemo, test } from "./fixtures";
import type { Page } from "@playwright/test";

/** Presses Tab until the focused element matches, failing after `max` presses. */
async function tabTo(page: Page, matches: (el: { label: string; tag: string }) => boolean, max = 40) {
  for (let i = 0; i < max; i++) {
    await page.keyboard.press("Tab");
    const info = await page.evaluate(() => {
      const el = document.activeElement as HTMLElement | null;
      return { label: (el?.getAttribute("aria-label") ?? el?.textContent ?? "").trim(), tag: el?.tagName ?? "" };
    });
    if (matches(info)) return;
  }
  throw new Error("Could not reach the element with Tab");
}

test("keyboard only: onboarding, find a phone, chat, details and back", async ({ page }) => {
  await openDemo(page, "firstRun");
  await tabTo(page, (el) => el.label === "Get started");
  await page.keyboard.press("Enter");
  await tabTo(page, (el) => el.label === "Continue");
  await page.keyboard.press("Enter");
  await page.keyboard.type("Kim");
  await page.keyboard.press("Enter");
  await expect(page.locator(".sidebar__me")).toContainText("Kim");

  // Skip link comes first.
  await page.keyboard.press("Tab");
  await expect(page.getByRole("link", { name: /Skip to/ })).toBeFocused();

  await tabTo(page, (el) => el.label.startsWith("Find a nearby phone"));
  await page.keyboard.press("Enter");
  await expect(page.locator(".chat__name")).toBeVisible({ timeout: 10_000 });

  // In the chat the composer has focus; type and send with Enter.
  await expect(page.getByRole("textbox", { name: /^Message / })).toBeFocused();
  await page.keyboard.type("Hello from the keyboard");
  await page.keyboard.press("Enter");
  await expect(page.locator(".message .bubble", { hasText: "Hello from the keyboard" })).toBeVisible();

  await tabTo(page, (el) => el.label === "Contact details");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("heading", { name: "Contact" })).toBeFocused();
  await tabTo(page, (el) => el.label === "Mark as verified");
  await page.keyboard.press("Enter");
  await expect(page.locator(".safety__state")).toHaveText("Verified");

  await tabTo(page, (el) => el.label === "Remove contact");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByRole("dialog").getByRole("button", { name: "Cancel" })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toBeHidden();
});

test("focus is visible", async ({ page }) => {
  await openDemo(page, "populated");
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  const outline = await page.evaluate(() => {
    const el = document.activeElement as HTMLElement;
    const style = getComputedStyle(el);
    return { style: style.outlineStyle, width: Number.parseFloat(style.outlineWidth) };
  });
  expect(outline.style).not.toBe("none");
  expect(outline.width).toBeGreaterThanOrEqual(2);
});
