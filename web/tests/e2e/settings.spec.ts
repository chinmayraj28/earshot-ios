import { expect, openDemo, test } from "./fixtures";

test("rename: cleaned like the phone, shown in the sidebar", async ({ page }) => {
  await openDemo(page, "populated");
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByRole("heading", { name: "Settings" })).toBeFocused();
  const name = page.getByRole("textbox", { name: "Your name" });
  const save = page.getByRole("button", { name: "Save" });
  await expect(save).toBeDisabled();
  await name.fill("   ");
  await expect(save).toBeDisabled();
  await name.fill("  Alex   Rivera ");
  await save.click();
  await expect(name).toHaveValue("Alex Rivera");
  await expect(page.getByText(/Saved\. Phones see the new name/)).toBeVisible();
  await expect(page.locator(".sidebar__me")).toContainText("Alex Rivera");
});

test("How it works and Privacy pages, with Back", async ({ page }) => {
  await openDemo(page, "populated");
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "How Earshot works" }).click();
  await expect(page.getByRole("heading", { name: "How Earshot works" })).toBeVisible();
  await expect(page.getByText(/Closing the tab or the browser ends the connection/)).toBeVisible();
  await page.getByRole("button", { name: "Back to settings" }).click();
  await page.getByRole("button", { name: "Privacy" }).click();
  await expect(page.getByText(/Earshot has no servers and no accounts/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "What Earshot doesn't protect against" })).toBeVisible();
});

test("show-text setting is off by default and remembered", async ({ page }) => {
  await openDemo(page, "populated");
  await page.getByRole("button", { name: "Settings" }).click();
  const toggle = page.getByRole("switch", { name: "Show message text in notifications" });
  await expect(toggle).not.toBeChecked();
  await toggle.check();
  await page.reload();
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByRole("switch", { name: "Show message text in notifications" })).toBeChecked();
});

test("erase everything asks first, then starts over", async ({ page }) => {
  await openDemo(page, "populated");
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Erase everything" }).click();
  const dialog = page.getByRole("dialog", { name: "Erase everything?" });
  await expect(dialog).toContainText("It can't be undone");
  await dialog.getByRole("button", { name: "Erase everything" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Earshot" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Get started" })).toBeVisible();
});
