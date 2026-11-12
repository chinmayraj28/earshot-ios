import { composer, expect, openDemo, row, test } from "./fixtures";

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true });

test("narrow screens: list, then chat, then back (button and browser Back)", async ({ page }) => {
  await openDemo(page, "populated");
  await expect(page.locator(".sidebar")).toBeVisible();
  await expect(page.locator(".main")).toBeHidden();

  await row(page, "Maya Okafor").click();
  await expect(page.locator(".sidebar")).toBeHidden();
  await expect(composer(page)).toBeVisible();

  await page.getByRole("button", { name: "Back to conversations" }).click();
  await expect(page.locator(".sidebar")).toBeVisible();
  await expect(page.locator(".main")).toBeHidden();

  // Android's back gesture is the browser's Back.
  await row(page, "Jonas Weber").click();
  await page.getByRole("button", { name: "Contact details", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Contact" })).toBeVisible();
  await page.goBack();
  await expect(composer(page)).toBeVisible();
  await page.goBack();
  await expect(page.locator(".sidebar")).toBeVisible();
  // The address never changes: no names or IDs in the URL.
  expect(new URL(page.url()).search).toBe("?demo=populated");
});

test("narrow screens: request progress shows while a chat is open", async ({ page }) => {
  await openDemo(page, "populated", "declined");
  await row(page, "Jonas Weber").click();
  await page.getByRole("button", { name: "Reconnect" }).click();
  await expect(page.locator(".floating-tray .request")).toContainText(/No answer/, { timeout: 10_000 });
});

test("320 px wide: nothing scrolls sideways", async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 640 });
  await openDemo(page, "populated");
  const overflow = () => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(await overflow()).toBeLessThanOrEqual(0);
  await row(page, "Maya Okafor").click();
  expect(await overflow()).toBeLessThanOrEqual(0);
  await page.getByRole("button", { name: "Contact details", exact: true }).click();
  expect(await overflow()).toBeLessThanOrEqual(0);
});

test("touch targets are at least 44 px", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  const sizes = await page.locator("button:visible").evaluateAll((buttons) =>
    buttons.map((button) => {
      const box = button.getBoundingClientRect();
      return { label: button.getAttribute("aria-label") ?? button.textContent?.trim() ?? "", width: box.width, height: box.height };
    }),
  );
  for (const size of sizes) {
    expect.soft(Math.min(size.width, size.height), size.label).toBeGreaterThanOrEqual(44);
  }
});
