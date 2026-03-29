import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  // Nix provides effective reproducibility. As such, flaky tests are bugs.
  retries: 0, // Agents: you MAY NOT increase this value.
  fullyParallel: true,
  workers: 1, // One test per derivation — no Playwright-level parallelism
  reporter: [["list"]],
  use: {
    headless: true,
    screenshot: "on",
    launchOptions: {
      executablePath:
        process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined,
    },
  },
  projects: [
    {
      name: "claude",
      use: { agentType: "claude" } as any,
    },
    {
      name: "codex",
      use: { agentType: "codex" } as any,
    },
    {
      name: "copilot",
      use: { agentType: "copilot" } as any,
    },
    {
      name: "failure",
      testDir: "./failure",
      use: { agentType: "claude" } as any,
    },
  ],
});
