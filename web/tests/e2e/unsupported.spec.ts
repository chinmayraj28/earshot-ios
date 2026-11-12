import { expect, test } from "./fixtures";

test("a browser without Web Bluetooth gets a clear full-page explanation", async ({ page }) => {
  await page.addInitScript(() => {
    // Make this Chromium look like Safari or Firefox: no navigator.bluetooth at all.
    const proto = Object.getPrototypeOf(navigator) as object;
    if ("bluetooth" in proto) delete (proto as { bluetooth?: unknown }).bluetooth;
    if ("bluetooth" in navigator) delete (navigator as { bluetooth?: unknown }).bluetooth;
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "This browser can't use Bluetooth" })).toBeVisible();
  await expect(page.getByText(/Safari, Firefox and every browser on iPhone/)).toBeVisible();
  await expect(page.getByText(/open this page in Chrome or Edge/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Find a nearby phone" })).toHaveCount(0);
});
