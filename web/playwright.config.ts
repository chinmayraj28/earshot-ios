import { defineConfig, devices } from "@playwright/test";

/**
 * Interface tests against the in-memory demo engine (no Bluetooth needed).
 *
 * - "app" runs every spec against the Vite dev server on port 5183 (E2E_PORT to change it).
 * - "production" builds the app and serves the build (port 5184, E2E_PREVIEW_PORT) to check
 *   the strict Content-Security-Policy, the service worker and opening with no network.
 *
 * Screenshots for docs/screenshots/web/ are taken only when SCREENSHOTS=1 is set.
 */
const port = Number(process.env.E2E_PORT ?? 5183);
const previewPort = Number(process.env.E2E_PREVIEW_PORT ?? 5184);
const buildDir = "node_modules/.cache/earshot-e2e-build";

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  reporter: [["list"]],
  timeout: 30_000,
  expect: { timeout: 6_000 },
  use: {
    ...devices["Desktop Chrome"],
    trace: "retain-on-failure",
  },
  projects: [
    {
      name: "app",
      testIgnore: /production\.spec\.ts/,
      use: { baseURL: `http://localhost:${port}` },
    },
    {
      name: "production",
      testMatch: /production\.spec\.ts/,
      use: { baseURL: `http://localhost:${previewPort}` },
    },
  ],
  webServer: [
    {
      command: `npx vite --port ${port} --strictPort`,
      url: `http://localhost:${port}`,
      reuseExistingServer: true,
      timeout: 60_000,
    },
    {
      command: `npx vite build --outDir ${buildDir} --emptyOutDir --logLevel warn && npx vite preview --outDir ${buildDir} --port ${previewPort} --strictPort`,
      url: `http://localhost:${previewPort}`,
      reuseExistingServer: false,
      timeout: 180_000,
    },
  ],
});
