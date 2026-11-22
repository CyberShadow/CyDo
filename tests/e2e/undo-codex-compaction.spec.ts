import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

test(
  "codex undoes a turn across a compaction and continues",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // ignore non-JSON frames
        }
      });
    });

    await enterSession(page);
    const timeout = responseTimeout(agentType);

    await sendMessage(page, "trigger compaction");
    await expect(assistantText(page, "Ready for compaction.")).toBeVisible({
      timeout,
    });

    await sendMessage(page, 'reply with "After compaction."');
    await expect(assistantText(page, "After compaction.")).toBeVisible({
      timeout,
    });

    await expect(page.locator(".compact-boundary-message")).toBeVisible({
      timeout,
    });

    // The first user message of a session is folded into the session-start
    // SYSTEM prompt and has no undo affordance at all (finding F2). Pin the
    // session-start-folded message with .first(): if compaction context
    // re-injection ever renders a second "trigger compaction" match, .last()
    // would silently retarget it and this assertion would stop testing F2
    // while still passing.
    const foldedWrapper = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".message.user-message:visible", {
          hasText: "trigger compaction",
        }),
      })
      .first();
    await foldedWrapper.hover();
    await expect(foldedWrapper.locator(".undo-btn")).toHaveCount(0);

    // Codex compacted the context while running the second turn. Undoing
    // that turn takes the thread back to before the compaction.
    const compacted = page
      .locator(".message-wrapper:visible", {
        has: page.locator(
          ".message.user-message:visible:not(.pending):not(.meta-message)",
          { hasText: 'reply with "After compaction."' },
        ),
      })
      .last();
    await compacted.hover();
    await expect(compacted.locator(".undo-btn")).toBeVisible();
    const frameStart = frames.length;
    await compacted.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "1 whole turn will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    await expect(assistantText(page, "After compaction.")).toHaveCount(0);
    await expect(assistantText(page, "Ready for compaction.")).toBeVisible();
    await expect(page.locator(".compact-boundary-message")).toHaveCount(0);
    expect(
      frames.slice(frameStart).filter((frame) => frame?.type === "error"),
    ).toEqual([]);

    await sendMessage(page, 'Please reply with "compact-final"');
    await expect(assistantText(page, "compact-final")).toBeVisible({
      timeout,
    });
  },
);
