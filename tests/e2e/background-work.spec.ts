import { existsSync, rmSync, writeFileSync } from "node:fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  type Page,
} from "./fixtures";

// An agent that ends its turn with work still running in the background (a
// command started with run_in_background, a Monitor) either waits for it (the
// CLI starts a turn of its own when that work reports) or forgot about it.
// CyDo asks the agent, once. An agent that ends its turn again is waiting:
// its task is not idle, asks for no attention and delivers no result to a
// parent. An agent that stops the work instead is done like after any turn.

type Snapshot = {
  tid: number;
  parentTid: number;
  status: string;
  isProcessing: boolean;
  needsAttention: boolean;
};

function captureTaskSnapshots(page: Page): Snapshot[] {
  const snapshots: Snapshot[] = [];
  page.on("websocket", (ws) => {
    ws.on("framereceived", (frame) => {
      let data: {
        type?: string;
        task?: {
          tid: number;
          parent_tid: number;
          status: string;
          isProcessing: boolean;
          needsAttention: boolean;
        };
      };
      try {
        data = JSON.parse(frame.payload.toString());
      } catch {
        return; // not a JSON frame
      }
      if (data.type !== "task_updated" || !data.task) return;
      snapshots.push({
        tid: data.task.tid,
        parentTid: data.task.parent_tid,
        status: data.task.status,
        isProcessing: data.task.isProcessing,
        needsAttention: data.task.needsAttention,
      });
    });
  });
  return snapshots;
}

/** The snapshots of one task from its first turn on. */
function sinceFirstTurn(snapshots: Snapshot[], tid: number): Snapshot[] {
  const mine = snapshots.filter((s) => s.tid === tid);
  const start = mine.findIndex((s) => s.isProcessing);
  return start < 0 ? [] : mine.slice(start);
}

/** The task whose turn started first: the one the test's message went to. */
async function firstWorkingTid(snapshots: Snapshot[]): Promise<number> {
  const working = () => snapshots.find((s) => s.isProcessing);
  await expect.poll(() => working() !== undefined).toBe(true);
  return working()!.tid;
}

/** A command that blocks until the test writes to `fifo`. */
function blockOn(fifo: string): string {
  return `mkfifo ${fifo} && read r < ${fifo}`;
}

// Short, so that the prompt carrying it stays on one line of the input box.
function uniquePath(): string {
  return `/tmp/bgw-${Math.random().toString(36).slice(2, 10)}`;
}

async function expectSessionWaitsForBackgroundWork(
  page: Page,
  prompt: (fifo: string) => string,
) {
  const fifo = uniquePath();
  const snapshots = captureTaskSnapshots(page);
  try {
    await enterSession(page);
    await sendMessage(page, prompt(fifo));
    const tid = await firstWorkingTid(snapshots);
    await expect.poll(() => existsSync(fifo)).toBe(true);

    // The turn that started the background work ends, the agent confirms
    // that it is waiting for it, and the task settles: waiting, never idle,
    // with nothing asked of the user.
    const settled = () =>
      sinceFirstTurn(snapshots, tid).find(
        (s) => !s.isProcessing && s.status !== "active",
      );
    await expect.poll(() => settled() !== undefined).toBe(true);
    expect(settled()).toMatchObject({
      status: "waiting",
      needsAttention: false,
    });
    const icon = page.locator(`.sidebar-item[data-tid="${tid}"] .task-type-icon`);
    await expect(icon).toHaveClass(/\bwaiting\b/);

    // Once the work is over and the agent has reacted to it, the task is
    // idle like after any other turn.
    writeFileSync(fifo, "release\n");
    await expect
      .poll(() => sinceFirstTurn(snapshots, tid).at(-1))
      .toMatchObject({ status: "alive", isProcessing: false });
    const history = sinceFirstTurn(snapshots, tid);
    const firstIdle = history.findIndex((s) => s.status === "alive");
    expect(
      history.slice(0, firstIdle).some((s) => s.needsAttention),
    ).toBe(false);
  } finally {
    rmSync(fifo, { force: true });
  }
}

test(
  "a session waits for its background command instead of going idle",
  { tag: "@claude-only" },
  async ({ page }) => {
    await expectSessionWaitsForBackgroundWork(
      page,
      (fifo) => `run detached command ${blockOn(fifo)}`,
    );
  },
);

test(
  "a session waits for its monitor instead of going idle",
  { tag: "@claude-only" },
  async ({ page }) => {
    await expectSessionWaitsForBackgroundWork(
      page,
      (fifo) => `run monitor ${blockOn(fifo)} && echo monitor-event`,
    );
  },
);

test(
  "a sub-task's result waits for its background command",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fifo = uniquePath();
    const marker = uniquePath();
    const snapshots = captureTaskSnapshots(page);
    try {
      await enterSession(page);
      await sendMessage(
        page,
        `call task research run detached command ${blockOn(fifo)} && touch ${marker}`,
      );
      const parentTid = await firstWorkingTid(snapshots);
      await expect.poll(() => existsSync(fifo)).toBe(true);
      const childTid = snapshots.find((s) => s.parentTid === parentTid)!.tid;

      // The sub-task's turn ends with its command still running, and the
      // agent confirms that it is waiting for it: the sub-task is not
      // finished, so nothing is delivered to the parent yet.
      const settled = () =>
        sinceFirstTurn(snapshots, childTid).find(
          (s) => !s.isProcessing && s.status !== "active",
        );
      await expect.poll(() => settled() !== undefined).toBe(true);
      expect(settled()).toMatchObject({ status: "waiting" });

      // The command finishes, the sub-task reacts to that and only then
      // completes; the parent gets the result of the whole work.
      writeFileSync(fifo, "release\n");
      await expect(
        page
          .locator('[style*="display: contents"] .message-list .cydo-task-spec')
          .last(),
      ).toBeVisible();
      expect(existsSync(marker)).toBe(true);
      await expect
        .poll(() => sinceFirstTurn(snapshots, childTid).at(-1))
        .toMatchObject({ status: "completed" });
    } finally {
      rmSync(fifo, { force: true });
      rmSync(marker, { force: true });
    }
  },
);

test(
  "a sub-task that forgot its background command stops it and completes",
  { tag: "@claude-only" },
  async ({ page }) => {
    const fifo = uniquePath();
    const snapshots = captureTaskSnapshots(page);
    try {
      await enterSession(page);
      await sendMessage(
        page,
        `call task research run forgotten command ${blockOn(fifo)}`,
      );
      const parentTid = await firstWorkingTid(snapshots);
      await expect.poll(() => existsSync(fifo)).toBe(true);
      const childTid = snapshots.find((s) => s.parentTid === parentTid)!.tid;

      // Nothing ever writes to the FIFO: the command would run forever.
      // Reminded of it, the agent stops it, and its sub-task is finished.
      const settled = () =>
        sinceFirstTurn(snapshots, childTid).find(
          (s) => !s.isProcessing && s.status !== "active",
        );
      await expect.poll(() => settled() !== undefined).toBe(true);
      expect(settled()).toMatchObject({ status: "completed" });
      await expect(
        page
          .locator('[style*="display: contents"] .message-list .cydo-task-spec')
          .last(),
      ).toBeVisible();
    } finally {
      rmSync(fifo, { force: true });
    }
  },
);
