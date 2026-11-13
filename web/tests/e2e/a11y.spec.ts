import AxeBuilder from "@axe-core/playwright";
import { expect, openDemo, row, test } from "./fixtures";
import type { Page } from "@playwright/test";

async function expectNoViolations(page: Page) {
  // Let entrance animations finish so colours are measured at full opacity.
  await page.waitForTimeout(600);
  const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"]).analyze();
  const summary = results.violations.map((violation) => `${violation.id}: ${violation.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  expect(summary).toEqual([]);
}

for (const scheme of ["light", "dark"] as const) {
  test.describe(`axe, ${scheme} mode`, () => {
    test.use({ colorScheme: scheme });

    test("onboarding", async ({ page }) => {
      await openDemo(page, "firstRun");
      await expectNoViolations(page);
      await page.getByRole("button", { name: "Get started" }).click();
      await page.getByRole("button", { name: "Continue" }).click();
      await expectNoViolations(page);
    });

    test("list and chat", async ({ page }) => {
      await openDemo(page, "populated");
      await expectNoViolations(page);
      await row(page, "Alice Huang").click();
      await expectNoViolations(page);
    });

    test("contact details and settings", async ({ page }) => {
      await openDemo(page, "populated");
      await row(page, "Jensen Huang").click();
      await page.getByRole("button", { name: "Contact details", exact: true }).click();
      await expectNoViolations(page);
      await page.getByRole("button", { name: "Settings" }).click();
      await expectNoViolations(page);
    });
  });
}
