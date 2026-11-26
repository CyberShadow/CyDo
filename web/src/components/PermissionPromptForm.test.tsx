// @vitest-environment jsdom
import { createRef } from "preact";
import { act } from "preact/test-utils";
import { ownedRoots } from "../test-support/preactAct";
import { describe, expect, it, vi } from "vitest";
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

const roots = ownedRoots();

function renderPermissionQuoteForm() {
  const root = roots.create();
  const insertTextRef = createRef<(text: string) => void>();
  const onDeny = vi.fn();
  const render = (sending = false) => {
    roots.render(
      <PermissionPromptForm
        toolName="Bash"
        input={{ command: "ls" }}
        sending={sending}
        onAllow={() => {}}
        onDeny={onDeny}
        insertTextRef={insertTextRef}
      />,
      root,
    );
  };
  render();
  const deny = () =>
    act(() => {
      root.querySelector<HTMLButtonElement>(".permission-deny-btn")!.click();
    });
  return { root, insertTextRef, onDeny, render, deny };
}

it("registers the reason inserter when Deny is opened", async () => {
  const { insertTextRef, deny } = renderPermissionQuoteForm();
  expect(insertTextRef.current).toBeNull();
  await deny();
  expect(insertTextRef.current).toBeTypeOf("function");
});

it("appends the exact quote to the submitted denial reason", async () => {
  const { root, insertTextRef, onDeny, deny } = renderPermissionQuoteForm();
  await deny();
  const reason = root.querySelector("textarea")!;
  await act(() => {
    reason.value = "Existing reason  ";
    reason.dispatchEvent(new Event("input", { bubbles: true }));
    reason.setSelectionRange(0, 8);
  });

  await act(() => {
    insertTextRef.current!("> quote\n\n");
  });
  expect(reason.value).toBe("Existing reason\n\n> quote\n\n");
  await deny();
  expect(onDeny).toHaveBeenCalledWith("Existing reason\n\n> quote\n\n");
});

it("unregisters the reason inserter while sending", async () => {
  const { insertTextRef, render, deny } = renderPermissionQuoteForm();
  await deny();
  expect(insertTextRef.current).toBeTypeOf("function");
  render(true);
  expect(insertTextRef.current).toBeNull();
});
