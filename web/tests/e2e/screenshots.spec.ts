/**
 * Captures the screenshots in docs/screenshots/web/. Only runs with SCREENSHOTS=1:
 *   SCREENSHOTS=1 npx playwright test screenshots --project=app
 */
import { expect, openDemo, row, test } from "./fixtures";
import type { Page } from "@playwright/test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../docs/screenshots/web");
test.skip(!process.env.SCREENSHOTS, "Set SCREENSHOTS=1 to capture screenshots.");

const sizes = { wide: { width: 1280, height: 800 }, narrow: { width: 390, height: 844 } } as const;

async function capture(page: Page, name: string) {
  // Freeze the radiating rings so pictures are stable.
  await page.addStyleTag({ content: ".rings__pulse{display:none!important}.rings--animated .rings__still{display:inline!important}*{animation:none!important;caret-color:transparent!important}" });
  await page.waitForTimeout(150);
  await page.screenshot({ path: path.join(dir, `${name}.png`) });
}

for (const scheme of ["light", "dark"] as const) {
  for (const [size, viewport] of Object.entries(sizes)) {
    test.describe(`${size} ${scheme}`, () => {
      test.use({ colorScheme: scheme, viewport });
      const tag = `${size}-${scheme}`;

      test("onboarding", async ({ page }) => {
        await openDemo(page, "firstRun");
        await capture(page, `onboarding-welcome-${tag}`);
        await page.getByRole("button", { name: "Get started" }).click();
        await capture(page, `onboarding-how-it-works-${tag}`);
      });

      test("home and chat", async ({ page }) => {
        await openDemo(page, "populated");
        await capture(page, `home-${tag}`);
        await row(page, "Maya Okafor").click();
        await expect(page.locator(".chat__name")).toBeVisible();
        await page.locator(".composer__input").blur();
        await capture(page, `chat-${tag}`);
        await page.getByRole("button", { name: size === "narrow" ? "Back to conversations" : "Settings" }).click();
        await row(page, "Jonas Weber").click();
        await page.locator(".composer__input").blur();
        await capture(page, `chat-out-of-range-${tag}`);
      });

      test("finding and failure", async ({ page }) => {
        await openDemo(page, "empty");
        await capture(page, `empty-${tag}`);
        await page.getByRole("button", { name: "Find a nearby phone" }).click();
        await expect(page.locator(".sidebar .request")).toBeVisible();
        await capture(page, `find-waiting-${tag}`);
        await openDemo(page, "empty", "declined");
        await page.getByRole("button", { name: "Find a nearby phone" }).click();
        await expect(page.locator(".sidebar .request")).toContainText("No answer", { timeout: 10_000 });
        await capture(page, `find-no-answer-${tag}`);
      });

      test("contact details and settings", async ({ page }) => {
        await openDemo(page, "populated");
        await row(page, "Maya Okafor").click();
        await page.getByRole("button", { name: "Contact details", exact: true }).click();
        await capture(page, `contact-details-${tag}`);
        await page.getByRole("button", { name: "Remove contact" }).click();
        await capture(page, `confirm-remove-${tag}`);
        await page.keyboard.press("Escape");
        if (size === "narrow") {
          await page.getByRole("button", { name: "Back to chat" }).click();
          await page.getByRole("button", { name: "Back to conversations" }).click();
        }
        await page.getByRole("button", { name: "Settings" }).click();
        await capture(page, `settings-${tag}`);
      });

      test("unsupported browser", async ({ page }) => {
        await page.addInitScript(() => {
          const proto = Object.getPrototypeOf(navigator) as object;
          if ("bluetooth" in proto) delete (proto as { bluetooth?: unknown }).bluetooth;
        });
        await page.goto("/");
        await expect(page.getByRole("heading", { name: "This browser can't use Bluetooth" })).toBeVisible();
        await capture(page, `unsupported-${tag}`);
      });
    });
  }
}
