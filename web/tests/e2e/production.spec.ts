/**
 * Runs against the production build (vite build + vite preview), where the strict
 * Content-Security-Policy and the service worker are active.
 */
import { expect, openDemo, row, test } from "./fixtures";

test("strict Content-Security-Policy is in place and the app runs under it", async ({ page }) => {
  const violations: string[] = [];
  page.on("console", (message) => {
    if (/Content Security Policy/i.test(message.text())) violations.push(message.text());
  });
  await openDemo(page, "populated");
  const csp = await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute("content");
  expect(csp).toContain("default-src 'none'");
  expect(csp).toContain("script-src 'self'");
  expect(csp).not.toContain("unsafe-inline");
  expect(csp).toContain("connect-src 'self'");
  await row(page, "Jensen Huang").click();
  await expect(page.locator(".chat__name")).toContainText("Jensen Huang");
  expect(violations).toEqual([]);
  // No inline scripts in the built page.
  expect(await page.locator("script:not([src])").count()).toBe(0);
});

test("after one visit the app opens with no network at all", async ({ page, context }) => {
  await openDemo(page, "populated");
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
  });
  // Wait until this page is controlled and the shell is cached.
  await page.reload();
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
  await expect
    .poll(() => page.evaluate(async () => (await caches.keys()).length > 0 && (await (await caches.open((await caches.keys())[0] ?? "")).keys()).length > 2))
    .toBe(true);

  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Conversations" })).toBeVisible();
  await row(page, "Jensen Huang").click();
  await expect(page.locator(".chat__name")).toContainText("Jensen Huang");
  await context.setOffline(false);
});

test("web app manifest and icons are served", async ({ page, request }) => {
  await openDemo(page, "populated");
  const manifest = await request.get("/manifest.webmanifest");
  expect(manifest.ok()).toBe(true);
  const json = (await manifest.json()) as { name: string; icons: Array<{ src: string }> };
  expect(json.name).toBe("Earshot");
  for (const icon of json.icons) expect((await request.get(`/${icon.src}`)).ok()).toBe(true);
});
