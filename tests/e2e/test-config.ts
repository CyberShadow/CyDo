import { readFileSync, writeFileSync } from "fs";
import { join } from "path";

const testConfigBasePath = join(__dirname, "test-config-base.yaml");

/**
 * Prepend the common e2e settings to a complete CyDo config: dev mode (so
 * unknown agent data reaches the post-test assertions) and the explicit
 * child environment.
 *
 * Agent launch clears its environment by default. Every e2e config replacement
 * must retain this fragment instead of relying on the backend's parent env.
 */
export function withTestAgentEnvironment(config: string): string {
  const base = readFileSync(testConfigBasePath, "utf8").trimEnd();
  return base + "\n" + config.trim() + "\n";
}

export function writeTestConfig(path: string, config: string): void {
  writeFileSync(path, withTestAgentEnvironment(config));
}
