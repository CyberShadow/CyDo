import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
  currentTaskTid,
  historyPathForTask,
  readHistoryFile,
} from "./fixtures";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const captureDir = mkdtempSync(join(tmpdir(), "cydo-claude-steering-capture-"));
test.use({
  backendEnv: {
    CYDO_REAL_CLAUDE_BIN: process.env.CYDO_CLAUDE_BIN ?? "claude",
    CYDO_CLAUDE_BIN: join(__dirname, "..", "claude-capture-wrapper.sh"),
    CYDO_CAPTURE_DIR: captureDir,
  },
});

function lines(path: string): string[] {
  try {
    return readHistoryFile(path).split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function completeCaptureLines(name: string): string[] {
  try {
    const capture = readFileSync(join(captureDir, name), "utf8");
    const lastNewline = capture.lastIndexOf("\n");
    if (lastNewline < 0) return [];
    return capture
      .slice(0, lastNewline + 1)
      .split("\n")
      .filter(Boolean);
  } catch {
    return [];
  }
}

function capturedInputLines(): any[] {
  return completeCaptureLines("stdin.ndjson").map((line) => JSON.parse(line));
}

// Claude stdout is a mixed stream; retain only JSON object records while
// ignoring native text and JSON arrays emitted alongside stream-json events.
function capturedStdoutRecords(): any[] {
  return completeCaptureLines("stdout.ndjson").flatMap((line) => {
    try {
      const record = JSON.parse(line);
      return record && typeof record === "object" && !Array.isArray(record)
        ? [record]
        : [];
    } catch {
      return [];
    }
  });
}

function queuedUser(page: import("@playwright/test").Page, text: string) {
  return page
    .locator(".message-wrapper:visible", {
      has: page.locator(".message.user-message:visible:not(.meta-message)", {
        hasText: text,
      }),
    })
    .last();
}

function eventHasText(event: any, text: string) {
  return (
    (typeof event?.text === "string" && event.text.includes(text)) ||
    (Array.isArray(event?.content) &&
      event.content.some(
        (block: any) =>
          block?.type === "text" &&
          typeof block.text === "string" &&
          block.text.includes(text),
      ))
  );
}

test(
  "Claude queue boundaries withhold live actions and retain offline undo",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const marker = "PROVISIONAL_QUEUE_BOUNDARY";
    const prompt = `Please reply with "${marker}"`;
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {}
      });
    });
    await enterSession(page);
    await sendMessage(page, 'Please reply with "steering-baseline"');
    await expect(assistantText(page, "steering-baseline")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect
      .poll(
        () =>
          capturedInputLines().filter((line) => line.type === "user").length,
      )
      .toBeGreaterThan(0);
    const baselineInput = capturedInputLines().find(
      (line) => line.type === "user",
    );
    expect(baselineInput?.uuid).toBeTruthy();
    const tid = currentTaskTid(page);
    const historyPath = historyPathForTask(tid);
    await expect
      .poll(
        () =>
          capturedStdoutRecords().filter(
            (line) =>
              line.type === "user" &&
              line.isReplay &&
              line.uuid === baselineInput.uuid,
          ).length,
      )
      .toBe(1);
    await expect
      .poll(
        () =>
          lines(historyPath)
            .map((line) => JSON.parse(line))
            .filter(
              (line) =>
                line.type === "user" && line.uuid === baselineInput.uuid,
            ).length,
      )
      .toBe(1);
    await expect(() => {
      const baselineFrames = frames.filter(
        (frame) =>
          frame?.type === "task_history_boundary_replaced" &&
          frame?.event?.type === "item/started" &&
          frame?.event?.item_type === "user_message" &&
          !frame?.event?.pending &&
          !frame?.event?.is_meta &&
          eventHasText(frame.event, 'Please reply with "steering-baseline"') &&
          frame?.event?.history_boundary?.kind === "user" &&
          frame?.event?.history_boundary?.anchor === baselineInput.uuid,
      );
      expect(baselineFrames).toHaveLength(1);
      expect(typeof baselineFrames[0].seq).toBe("number");
    }).toPass({ timeout: responseTimeout(agentType) });

    await killSession(page, agentType);
    await page.locator(".btn-banner-resume").click();
    await expect(page.locator(".btn-banner-stop")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await sendMessage(page, 'Please reply with "steering-resumed"');
    await expect(assistantText(page, "steering-resumed")).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const resumedInput = capturedInputLines().find(
      (line) =>
        line.type === "user" &&
        line.message?.content === 'Please reply with "steering-resumed"',
    );
    expect(resumedInput?.uuid).toBeTruthy();
    expect(resumedInput.uuid).not.toBe(baselineInput.uuid);
    await expect
      .poll(
        () =>
          capturedStdoutRecords().filter(
            (line) =>
              line.type === "user" &&
              line.isReplay &&
              line.uuid === resumedInput.uuid,
          ).length,
      )
      .toBe(1);
    await expect
      .poll(
        () =>
          lines(historyPath)
            .map(JSON.parse)
            .filter(
              (line) => line.type === "user" && line.uuid === resumedInput.uuid,
            ).length,
      )
      .toBe(1);
    await expect(() => {
      const resumedFrames = frames.filter(
        (frame) =>
          frame?.type === "task_history_boundary_replaced" &&
          frame?.event?.type === "item/started" &&
          frame?.event?.item_type === "user_message" &&
          !frame?.event?.pending &&
          !frame?.event?.is_meta &&
          eventHasText(frame.event, 'Please reply with "steering-resumed"') &&
          frame?.event?.history_boundary?.kind === "user" &&
          frame?.event?.history_boundary?.anchor === resumedInput.uuid,
      );
      expect(resumedFrames).toHaveLength(1);
    }).toPass({ timeout: responseTimeout(agentType) });
    await expect
      .poll(
        () =>
          lines(historyPath)
            .map((line) => JSON.parse(line))
            .filter(
              (line) =>
                line.type === "user" && line.uuid === baselineInput.uuid,
            ).length,
      )
      .toBe(1);

    await sendMessage(page, "run command sleep 5");
    await expect(
      page.locator(".tool-call", { hasText: "sleep 5" }),
    ).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const busyFrameStart = frames.length;
    await sendMessage(page, prompt);
    await expect
      .poll(() =>
        lines(historyPath).some(
          (line) =>
            line.includes('"operation":"enqueue"') && line.includes(marker),
        ),
      )
      .toBe(true);

    await expect
      .poll(() =>
        lines(historyPath).some(
          (line) =>
            line.includes('"type":"attachment"') &&
            line.includes('"source_uuid"'),
        ),
      )
      .toBe(true);
    const capturedInputs = capturedInputLines().filter(
      (line) => line.type === "user",
    );
    const queuedInput = capturedInputs.at(-1);
    expect(queuedInput?.uuid).toBeTruthy();
    expect(queuedInput.uuid).not.toBe(baselineInput.uuid);
    expect(
      lines(historyPath).some(
        (line) =>
          line.includes('"source_uuid"') && line.includes(queuedInput.uuid),
      ),
    ).toBe(true);
    await expect
      .poll(() =>
        capturedStdoutRecords().some(
          (line) =>
            line.type === "user" &&
            line.isReplay &&
            line.uuid === queuedInput?.uuid,
        ),
      )
      .toBe(true);
    expect(
      lines(historyPath)
        .map((line) => JSON.parse(line))
        .filter(
          (line) => line.type === "user" && line.uuid === queuedInput?.uuid,
        ),
    ).toHaveLength(0);
    await expect
      .poll(() =>
        lines(historyPath).some((line) => {
          const record = JSON.parse(line);
          return (
            record.type === "queue-operation" && record.operation === "remove"
          );
        }),
      )
      .toBe(true);
    const remove = lines(historyPath)
      .map((line) => JSON.parse(line))
      .find(
        (line) =>
          line.type === "queue-operation" && line.operation === "remove",
      );
    expect(remove.uuid).toBeFalsy();
    expect(remove.native_uuid).toBeFalsy();
    expect(remove.correlation_id).toBeFalsy();
    await expect(() => {
      const consumed = frames.filter(
        (frame) =>
          frame?.event?.type === "user_message/consumed" &&
          typeof frame?.event?.uuid === "string" &&
          frame.event.uuid.startsWith("enqueue-") &&
          frame.event.consumed_as === "removed",
      );
      expect(consumed).toHaveLength(1);
      expect(consumed[0].event.consumed_as).toBe("removed");
      expect(consumed[0].event.native_uuid).toBeFalsy();
      expect(consumed[0].event.correlation_id).toBeFalsy();
      expect(consumed[0].event.nonce).toBeFalsy();
      expect(
        frames.some(
          (frame) =>
            frame?.event?.type === "user_message/consumed" &&
            frame?.event?.uuid === queuedInput.uuid,
        ),
      ).toBe(false);
    }).toPass({ timeout: responseTimeout(agentType) });
    await expect
      .poll(() =>
        frames
          .slice(busyFrameStart)
          .some((frame) => frame?.event?.type === "turn/stop"),
      )
      .toBe(true);
    expect(
      frames.filter(
        (frame) =>
          frame?.type === "task_history_boundary_replaced" &&
          frame?.event?.type === "item/started" &&
          frame?.event?.item_type === "user_message" &&
          eventHasText(frame.event, prompt) &&
          frame?.event?.history_boundary,
      ),
    ).toHaveLength(0);

    const live = queuedUser(page, marker);
    await expect(live).toBeVisible({ timeout: responseTimeout(agentType) });
    await live.hover();
    await expect(live.locator(".fork-btn, .undo-btn")).toHaveCount(0);
    await expect(page.locator(".command-error-dialog")).toHaveCount(0);

    await killSession(page, agentType);
    await page.reload();
    const offline = queuedUser(page, marker);
    await expect(offline).toBeVisible({ timeout: responseTimeout(agentType) });
    await offline.hover();
    await expect(offline.locator(".undo-btn")).toBeVisible();
    await expect(offline.locator(".undo-btn")).not.toHaveAttribute(
      "title",
      /file checkpoint available/,
    );
    await expect(offline.locator(".fork-btn")).toHaveCount(0);
    await offline.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible();
    const fileRevert = page
      .locator(".undo-dialog-options input[type=checkbox]")
      .nth(1);
    await expect(fileRevert).toBeDisabled();
    await expect(page.locator(".undo-dialog-options")).toContainText(
      "no file checkpoint",
    );
    await page.locator(".btn-undo").click();
    await expect(assistantText(page, "steering-baseline")).toBeVisible();
    await expect(assistantText(page, "steering-resumed")).toBeVisible();
    await expect
      .poll(
        () =>
          lines(historyPath)
            .map(JSON.parse)
            .filter(
              (line) =>
                line.type === "user" &&
                (line.uuid === baselineInput.uuid ||
                  line.uuid === resumedInput.uuid),
            ).length,
      )
      .toBe(2);
    await expect(queuedUser(page, marker)).toHaveCount(0);
    await expect(page.locator(".input-textarea:visible").first()).toHaveValue(
      prompt,
    );
    expect(lines(historyPath).some((line) => line.includes(marker))).toBe(
      false,
    );
  },
);
