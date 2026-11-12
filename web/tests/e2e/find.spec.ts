import { composer, expect, openDemo, row, test } from "./fixtures";

test("find a nearby phone: waiting, then connected opens the chat", async ({ page }) => {
  await openDemo(page, "empty");
  await page.getByRole("button", { name: "Find a nearby phone" }).click();
  const card = page.locator(".sidebar .request");
  await expect(card).toContainText(/Waiting for \w+ to accept on their phone/);
  await expect(card.getByRole("button", { name: "Cancel request" })).toBeVisible();
  await expect(page.getByTestId("announcer")).toContainText(/Waiting for \w+ to accept/);

  // Connected: the new conversation opens by itself and the request card goes away.
  await expect(page.locator(".chat__name")).toBeVisible({ timeout: 10_000 });
  await expect(page.locator(".sidebar .request")).toHaveCount(0);
  await expect(page.locator(".sidebar .row")).toHaveCount(1);
  await expect(composer(page)).toBeVisible();
});

test("cancelling the browser's chooser shows nothing", async ({ page }) => {
  await openDemo(page, "empty", "cancelled");
  await page.getByRole("button", { name: "Find a nearby phone" }).click();
  await expect(page.getByRole("button", { name: "Find a nearby phone" })).toBeEnabled();
  await page.waitForTimeout(800);
  await expect(page.locator(".tray")).toHaveCount(0);
});

const pickFailures: Array<[string, RegExp]> = [
  ["notEarshot", /That device isn't running Earshot/],
  ["unreachable", /Couldn't reach that phone/],
  ["unavailable", /Couldn't connect to that phone/],
];

for (const [outcome, text] of pickFailures) {
  test(`picking fails with ${outcome}: plain reason and Try again`, async ({ page }) => {
    await openDemo(page, "empty", outcome);
    await page.getByRole("button", { name: "Find a nearby phone" }).click();
    const notice = page.locator(".sidebar .notice--problem");
    await expect(notice).toContainText(text);
    await expect(notice.getByRole("button", { name: "Try again" })).toBeVisible();
    await notice.getByRole("button", { name: "Dismiss" }).click();
    await expect(notice).toHaveCount(0);
  });
}

const requestFailures: Array<[string, RegExp]> = [
  ["declined", /No answer\. \w+ may have declined, missed it or moved away/],
  ["connectionLost", /The connection dropped while setting up/],
  ["verificationFailed", /couldn't confirm who this is/],
  ["incompatibleVersion", /versions of Earshot don't match/],
];

for (const [outcome, text] of requestFailures) {
  test(`request fails with ${outcome}: plain reason, retry and dismiss`, async ({ page }) => {
    await openDemo(page, "empty", outcome);
    await page.getByRole("button", { name: "Find a nearby phone" }).click();
    const card = page.locator(".sidebar .request");
    await expect(card).toContainText(text, { timeout: 10_000 });
    await expect(card.getByRole("button", { name: "Try again" })).toBeVisible();
    await card.getByRole("button", { name: "Dismiss" }).click();
    await expect(page.locator(".sidebar .request")).toHaveCount(0);
  });
}

test("Reconnect from an out-of-range chat sends the waiting message", async ({ page }) => {
  await openDemo(page, "populated", "savedContact");
  await row(page, "Jonas Weber").click();
  const waiting = page.locator('.message[data-status="waiting"]').first();
  await expect(waiting).toBeVisible();
  await page.getByRole("button", { name: "Reconnect" }).click();
  await expect(page.locator(".chat__head")).toContainText("Connected", { timeout: 10_000 });
  await expect(page.getByRole("button", { name: "Reconnect" })).toHaveCount(0);
  await expect(page.locator('.message[data-status="waiting"]')).toHaveCount(0, { timeout: 10_000 });
});
