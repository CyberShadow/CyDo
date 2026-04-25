import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { test, expect } from "@playwright/test";

test("e2e specs do not use raw assistant text-content selector", async () => {
  const e2eDir = join(process.cwd(), "e2e");
  const files = readdirSync(e2eDir).filter(
    (name) =>
      name.endsWith(".spec.ts") && name !== "assistant-selector-guard.spec.ts",
  );
  const bannedPattern =
    /\.message\.assistant-message(?:\s|>|~|\+)*\.text-content\b/;
  const offenders: string[] = [];

  for (const file of files) {
    const fullPath = join(e2eDir, file);
    const source = readFileSync(fullPath, "utf8");
    if (bannedPattern.test(source)) offenders.push(file);
  }

  expect(
    offenders,
    `Found banned assistant selector pattern "${bannedPattern}" in e2e specs`,
  ).toEqual([]);
});
