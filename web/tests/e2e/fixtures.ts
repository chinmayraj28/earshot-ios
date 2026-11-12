/**
 * Shared test setup. Every test automatically fails if the page:
 *  - logs a console error or throws, or
 *  - makes a network request to anywhere other than this local server.
 */
import { test as base, expect, type Page } from "@playwright/test";

export const test = base.extend<{ guard: void }>({
  guard: [
    async ({ page }, use) => {
      const errors: string[] = [];
      const external: string[] = [];
      page.on("console", (message) => {
        if (message.type() === "error") errors.push(message.text());
      });
      page.on("pageerror", (error) => errors.push(error.message));
      page.on("request", (request) => {
        const url = new URL(request.url());
        if (url.protocol === "data:" || url.protocol === "blob:") return;
        if (url.hostname !== "localhost" && url.hostname !== "127.0.0.1") external.push(request.url());
      });
      await use();
      expect(errors, "console errors").toEqual([]);
      expect(external, "requests to other sites").toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };

/** Opens the app with a demo scenario. `find` picks what "Find a nearby phone" does. */
export async function openDemo(page: Page, scenario: "populated" | "empty" | "firstRun", find?: string) {
  await page.goto(`/?demo=${scenario}${find ? `&find=${find}` : ""}`);
}

/** The conversation row button for a contact. */
export function row(page: Page, name: string) {
  return page.locator(".sidebar .row", { hasText: name });
}

/** The chat's message composer. */
export function composer(page: Page) {
  return page.getByRole("textbox", { name: /^Message / });
}
