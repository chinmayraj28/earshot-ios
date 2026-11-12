import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  server: { port: 5183, strictPort: true },
  preview: { port: 5183, strictPort: true },
  test: { include: ["tests/unit/**/*.test.ts"], environment: "node", testTimeout: 60_000 },
});
