import { composer, expect, openDemo, row, test } from "./fixtures";

test("send to a connected contact: Sending then Delivered", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  await expect(page.locator(".chat__name")).toHaveText(/Maya Okafor/);
  await expect(page.locator(".chat__head")).toContainText("Connected");

  await composer(page).fill("See you at the stairs");
  await composer(page).press("Enter");
  await expect(composer(page)).toHaveValue("");
  const sent = page.locator(".message", { hasText: "See you at the stairs" });
  await expect(sent).toHaveAttribute("data-direction", "outgoing");
  await expect(sent).toHaveAttribute("data-status", "delivered", { timeout: 8_000 });
  await expect(sent).toContainText("Delivered");
});

test("Shift+Enter adds a new line instead of sending", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  await composer(page).fill("first line");
  await composer(page).press("Shift+Enter");
  await composer(page).pressSequentially("second line");
  await expect(composer(page)).toHaveValue("first line\nsecond line");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page.locator(".message .bubble", { hasText: "second line" })).toBeVisible();
});

test("the counter appears near the 2000 character limit and the box stops at 2000", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  await composer(page).fill("x".repeat(1700));
  await expect(page.getByText(/characters left/)).toHaveCount(0);
  await composer(page).fill("x".repeat(1900));
  await expect(page.getByText("100 characters left")).toBeVisible();
  await composer(page).fill("x".repeat(2100));
  await expect(composer(page)).toHaveValue("x".repeat(2000));
  await expect(page.getByText("0 characters left")).toBeVisible();
});

test("a message to an out-of-range contact stays Waiting", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Jonas Weber").click();
  await expect(page.getByText(/Not connected to Jonas's phone/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Reconnect" })).toBeVisible();

  await composer(page).fill("Still at the trucks?");
  await composer(page).press("Enter");
  const waiting = page.locator(".message", { hasText: "Still at the trucks?" });
  await expect(waiting).toHaveAttribute("data-status", "waiting");
  await expect(waiting).toContainText("Waiting for Jonas to connect");
  await page.waitForTimeout(2_500);
  await expect(waiting).toHaveAttribute("data-status", "waiting");
  await expect(row(page, "Jonas Weber")).toContainText("Waiting: Still at the trucks?");
});

test("disconnect from a connected contact", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  await page.getByRole("button", { name: "Disconnect from Maya Okafor" }).click();
  await expect(page.getByText(/Not connected to Maya's phone/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Reconnect" })).toBeVisible();
});

test("reading history is not yanked to the bottom by a new message", async ({ page }) => {
  await openDemo(page, "populated");
  await row(page, "Maya Okafor").click();
  for (let i = 0; i < 14; i++) {
    await composer(page).fill(`Filler message number ${i} with some words to make it longer`);
    await composer(page).press("Enter");
  }
  const scroller = page.locator(".messages-scroll");
  // Following the newest message is a smooth scroll; let it finish before scrolling up to read.
  await expect.poll(() => scroller.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeLessThan(4);
  await page.waitForTimeout(400);
  await scroller.evaluate((el) => el.scrollTo({ top: 0 }));
  await page.waitForTimeout(200);
  const before = await scroller.evaluate((el) => el.scrollTop);
  expect(before).toBe(0);
  // Status changes (Sending to Delivered) and replies must not move the view while reading.
  await page.waitForTimeout(3_000);
  expect(await scroller.evaluate((el) => el.scrollTop)).toBe(0);
});
