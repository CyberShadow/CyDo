import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  // The test timeout is a hang detector, not a performance expectation: many
  // check derivations run concurrently (nix max-jobs), so wall-clock budgets
  // sized for an idle machine turn correctness tests into de facto
  // performance tests that flake under contention. Assertions are
  // condition-based and return the moment they are satisfied, so generous
  // budgets cost nothing on passing runs; only genuine failures report
  // slower. Hitting these limits means "wedged", never "the machine was
  // busy".
  timeout: 600_000,
  // Nix provides effective reproducibility. As such, flaky tests are bugs.
  retries: 0, // Agents: you MAY NOT increase this value.
  fullyParallel: true,
  workers: 1, // One test per derivation — no Playwright-level parallelism
  reporter: [["list"]],
  expect: {
    // Assertion waits share one generous budget (see timeout above); keep it
    // under the test timeout so a failing assertion reports its own
    // expected/received detail instead of a generic test timeout.
    timeout: 540_000,
  },
  use: {
    headless: true,
    screenshot: "on",
    actionTimeout: 540_000,
    navigationTimeout: 540_000,
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
