import { expect, it } from "vitest";
import styles from "../styles.css?inline";

it("uses the task bar dimensions to position the welcome theme toggle", () => {
  const corner = styles.match(/\.theme-toggle-corner\s*\{([^}]*)\}/)?.[1] ?? "";
  const bar = styles.match(/^\.task-bar\s*\{([^}]*)\}/m)?.[1] ?? "";
  for (const property of ["--task-bar-height", "--task-bar-pad-x"]) {
    expect(corner).toContain(`var(${property})`);
    expect(bar).toContain(`var(${property})`);
  }
  expect(corner).toContain("var(--icon-btn-size)");
});

it("styles disconnected and loading bars by connection state", () => {
  const disconnected = styles.match(
    /\.task-bar\[data-connection="disconnected"\]\s*\{([^}]*)\}/,
  )?.[1];
  const disconnectedChip = styles.match(
    /\.task-bar\[data-connection="disconnected"\]\s+\.task-bar-agent\b/,
  );
  const loadingChip = styles.match(
    /\.task-bar\[data-connection="loading"\]\s+\.task-bar-agent\s*\{([^}]*)\}/,
  )?.[1];
  expect(disconnected ?? "").toMatch(/border-bottom-color:\s*var\(--error\)/);
  expect(disconnectedChip).not.toBeNull();
  expect(loadingChip ?? "").toMatch(/animation:[^;}]*task-bar-pulse/);
});
