import { defineConfig } from "vitest/config";

const hangTimeout = 540_000;

export default defineConfig({
  test: {
    testTimeout: hangTimeout,
    hookTimeout: hangTimeout,
    teardownTimeout: hangTimeout,
    expect: { poll: { timeout: hangTimeout } },
    runner: "./src/test-support/timeoutIsolationRunner.ts",
    setupFiles: ["./src/test-support/shikiFullTokenization.ts"],
    include: ["src/**/*.test.ts", "src/**/*.test.tsx", "scripts/**/*.test.mjs"],
    css: {
      include: [/\/styles\.css(?:\?|$)/],
    },
  },
});
