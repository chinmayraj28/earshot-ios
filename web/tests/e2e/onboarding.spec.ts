import { expect, openDemo, test } from "./fixtures";

test("first run: welcome, how it works on the web, then a cleaned-up name", async ({ page }) => {
  await openDemo(page, "firstRun");
  await expect(page.getByRole("heading", { level: 1, name: "Earshot" })).toBeVisible();
  await expect(page.getByText("Text a nearby iPhone when the network is gone.")).toBeVisible();
  await expect(page.getByRole("img", { name: "Step 1 of 3" })).toBeVisible();

  await page.getByRole("button", { name: "Get started" }).click();
  await expect(page.getByRole("heading", { name: "How Earshot works on the web" })).toBeVisible();
  await expect(page.getByText("You always start")).toBeVisible();
  await expect(page.getByText(/phones can't find this browser/)).toBeVisible();
  await expect(page.getByText("Keep this tab open")).toBeVisible();

  await page.getByRole("button", { name: "Continue" }).click();
  const name = page.getByRole("textbox", { name: "Your name" });
  await expect(name).toBeFocused();
  const start = page.getByRole("button", { name: "Start using Earshot" });
  await expect(start).toBeDisabled();
  await name.fill("     ");
  await expect(start).toBeDisabled();

  // Longer than 32 characters is cut at 32 while typing.
  await name.fill("A".repeat(40));
  await expect(name).toHaveValue("A".repeat(32));
  await expect(page.getByText("32/32")).toBeVisible();

  await name.fill("   Sam    Lee  ");
  await start.click();
  await expect(page.getByText("The phone you connect to sees you as")).toContainText("Sam Lee");
  await expect(page.getByRole("button", { name: "Find a nearby phone" })).toBeVisible();
});

test("onboarding Back returns to the previous step", async ({ page }) => {
  await openDemo(page, "firstRun");
  await page.getByRole("button", { name: "Get started" }).click();
  await page.getByRole("button", { name: "Back" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Earshot" })).toBeVisible();
});
