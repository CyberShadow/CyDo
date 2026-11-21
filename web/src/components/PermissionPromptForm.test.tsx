import { describe, expect, it } from "vitest";
import { renderToString } from "preact-render-to-string";
import { PermissionPromptForm, formatTimeLeft } from "./PermissionPromptForm";

describe("PermissionPromptForm", () => {
  it("formats the time left before the prompt is denied", () => {
    expect(formatTimeLeft(120_000, 0)).toBe("2:00");
    expect(formatTimeLeft(120_000, 13_500)).toBe("1:47");
    expect(formatTimeLeft(120_000, 119_999)).toBe("0:01");
    expect(formatTimeLeft(120_000, 125_000)).toBe("0:00");
  });

  it("shows the countdown only when the prompt has a deadline", () => {
    const render = (expiresAt?: number) =>
      renderToString(
        <PermissionPromptForm
          toolName="Bash"
          input={{ command: "ls" }}
          expiresAt={expiresAt}
          onAllow={() => {}}
          onDeny={() => {}}
        />,
      );
    expect(render(Date.now() + 60_000)).toContain("Denied automatically in");
    expect(render()).not.toContain("permission-prompt-timeout");
  });
});
