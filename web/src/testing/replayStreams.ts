import type { AgnosticEvent, ItemStartedEvent } from "../protocol";
import { makeTaskState, type TaskState } from "../types";
import bashEditDiff from "../testFixtures/claude-bash-edit-diff.json";

type BoundaryEvent = AgnosticEvent & {
  history_boundary?: NonNullable<ItemStartedEvent["history_boundary"]>;
};

export type ReplayOperation =
  | { kind: "event"; event: AgnosticEvent; seq: number; ts: number }
  | { kind: "boundary"; event: BoundaryEvent; seq: number }
  | { kind: "ack"; nonce: string }
  | { kind: "reject"; nonce: string };

type Driver = "claude" | "codex";
const queuedMessages = [
  "ack",
  "reject",
  "replay",
  "pending-replay",
  "steering",
  "removed",
  "cancelled",
] as const;

export function replayInitialState(driver: Driver): TaskState {
  return {
    ...makeTaskState(1),
    driver,
    messages: queuedMessages.map((nonce, index) => ({
      id: `opt-${index + 1}`,
      type: "user",
      content: [{ type: "text", text: nonce }],
      ackState: nonce === "replay" || nonce === "pending-replay" ? 3 : 4,
      pending: true,
      nonce,
      isProvisional: true,
    })),
    msgIdCounter: queuedMessages.length,
  };
}

export function* replayStream(
  driver: Driver,
  seed: number,
): Generator<ReplayOperation> {
  let seq = 0;
  function* emit(event: BoundaryEvent): Generator<ReplayOperation> {
    const eventSeq = ++seq;
    yield {
      kind: "event",
      event,
      seq: eventSeq,
      ts: 1_700_000_000_000 + eventSeq,
    };
    if (event.history_boundary)
      yield { kind: "boundary", event, seq: eventSeq };
  }

  yield* emit({
    type: "session/init",
    session_id: "test-session",
    cwd: "/tmp/project",
    model: "initial-model",
    tools: [],
    agent_version: "1.0",
    permission_mode: "default",
    agent: driver,
    supports_file_revert: true,
  });
  yield* emit({ type: "session/metadata", model: "updated-model" });
  yield { kind: "ack", nonce: "ack" };
  yield { kind: "reject", nonce: "reject" };
  yield* emit({
    type: "item/started",
    item_type: "user_message",
    item_id: "replay-user",
    uuid: "replay-user",
    correlation_id: "replay",
    content: [{ type: "text", text: "replay" }],
    is_replay: true,
    history_boundary: { kind: "user", anchor: "replay-user" },
  });
  yield* emit({
    type: "item/started",
    item_type: "user_message",
    item_id: "pending-replay-user",
    uuid: "pending-replay-user",
    correlation_id: "pending-replay",
    content: [{ type: "text", text: "pending-replay" }],
    pending: true,
    is_replay: true,
  });
  for (const consumed_as of ["steering", "removed", "cancelled"]) {
    yield* emit({
      type: "user_message/consumed",
      uuid: "",
      consumed_as,
      correlation_id: consumed_as,
    });
  }
  yield* emit({
    type: "item/started",
    item_type: "user_message",
    item_id: "pending-user",
    uuid: "enqueue-1",
    pending: true,
    content: [{ type: "text", text: "queued" }],
    history_boundary: { kind: "provisional_user", anchor: "enqueue-1" },
  });
  yield* emit({
    type: "user_message/consumed",
    uuid: "enqueue-1",
    native_uuid: "native-1",
    consumed_as: "turn_start",
  });
  yield* emit({
    type: "item/started",
    item_type: "user_message",
    item_id: "native-1",
    uuid: "native-1",
    is_replay: true,
    content: [{ type: "text", text: "queued" }],
  });

  yield* emit({ type: "agent/unrecognized", reason: "top-level data" });
  yield* emit({
    type: "agent/notice",
    severity: "warning",
    subject: "Notice",
    body: "Top-level notice",
  });
  yield* emit({
    type: "cydo/task_diagnostic",
    severity: "warning",
    subject: "Diagnostic",
    body: "Top-level diagnostic",
  });
  yield* emit({ type: "agent/command_output", text: "Command output" });
  yield* emit({
    type: "control/response",
    response: { subtype: "success", request_id: "control-1" },
  });
  yield* emit({ type: "session/cost", total_cost_usd: 0.02 });

  for (let turn = 0; ; turn++) {
    seed = (Math.imul(1664525, seed) + 1013904223) >>> 0;
    const prefix = `turn-${turn}`;
    const item = `${prefix}-item`;
    const task = `${prefix}-task`;
    const text = `Generated text ${seed}`;
    yield* emit({
      type: "item/started",
      item_type: "user_message",
      item_id: `${prefix}-user`,
      uuid: `${prefix}-user`,
      content: [{ type: "text", text }],
      history_boundary: { kind: "user", anchor: `${prefix}-user` },
    });
    yield* emit({
      type: "item/started",
      item_type: "thinking",
      item_id: `${prefix}-thinking`,
      text,
    });
    yield* emit({ type: "item/completed", item_id: `${prefix}-thinking` });
    yield* emit({
      type: "item/started",
      item_type: "text",
      item_id: item,
      text,
    });
    yield* emit({
      type: "item/delta",
      item_id: item,
      delta_type: "text_delta",
      content: " delta",
    });
    yield* emit({ type: "item/completed", item_id: item });
    yield* emit({
      type: "item/started",
      item_type: "tool_use",
      item_id: task,
      name: "Task",
      tool_server: "cydo",
    });
    yield* emit({
      type: "cydo/item_enriched",
      item_id: task,
      spawned_child: { spec_index: 0, child_tid: 2 * turn + 2 },
    });
    yield* emit({
      type: "cydo/item_enriched",
      item_id: task,
      spawned_child: { spec_index: 1, child_tid: 2 * turn + 3 },
    });
    yield* emit({ type: "task/started", task_id: task, tool_use_id: task });
    yield* emit({ type: "task/updated", task_id: task, status: "running" });
    yield* emit({
      type: "item/started",
      item_type: "text",
      item_id: `${prefix}-child`,
      text,
      parent_tool_use_id: task,
      is_sidechain: true,
    });
    yield* emit({
      type: "turn/stop",
      parent_tool_use_id: task,
      is_sidechain: true,
    });
    yield* emit({
      type: "task/notification",
      task_id: task,
      status: "completed",
    });
    yield* emit({ type: "item/completed", item_id: task });
    yield* emit({ type: "item/result", item_id: task, content: "done" });

    const ask = `${prefix}-ask`;
    yield* emit({
      type: "item/started",
      item_type: "tool_use",
      item_id: ask,
      name: "Ask",
      tool_server: "cydo",
    });
    yield* emit({
      type: "cydo/item_enriched",
      item_id: ask,
      target_tid: 2 * turn + 2,
    });
    yield* emit({ type: "item/completed", item_id: ask });
    yield* emit({ type: "item/result", item_id: ask, content: "answered" });
    yield* emit({
      type: "cydo/item_enriched",
      item_id: ask,
      spawned_child: { spec_index: 0, child_tid: 2 * turn + 3 },
    });

    const read = `${prefix}-read`;
    yield* emit({
      type: "item/started",
      item_type: "tool_use",
      item_id: read,
      name: "Read",
    });
    yield* emit({
      type: "item/delta",
      item_id: read,
      delta_type: "text_delta",
      content: '{"file_path":"original"}',
    });
    yield* emit({
      type: "item/completed",
      item_id: read,
      text: '{"file_path":"replacement"}',
    });

    if (driver === "claude") {
      const bash = `${prefix}-bash`;
      yield* emit({
        type: "item/started",
        item_type: "tool_use",
        item_id: bash,
        name: "Bash",
        input: { command: "echo hello" },
      });
      yield* emit({ type: "item/permission", item_id: bash, stage: "asked" });
      yield* emit({
        type: "item/delta",
        item_id: bash,
        delta_type: "stdin_delta",
        content: "hello",
      });
      yield* emit({
        type: "item/delta",
        item_id: bash,
        delta_type: "output_delta",
        content: "hello",
      });
      yield* emit({ type: "item/completed", item_id: bash });
      yield* emit({
        type: "item/result",
        item_id: bash,
        content: "done",
        tool_result: { bashEditDiff },
      });
      for (const name of ["Edit", "Write"]) {
        const tool = `${prefix}-${name}`;
        yield* emit({
          type: "item/started",
          item_type: "tool_use",
          item_id: tool,
          name,
          input: {
            file_path: `/tmp/project/${name}.txt`,
            ...(name === "Write"
              ? { content: text }
              : { old_string: "old", new_string: text }),
          },
        });
        yield* emit({ type: "item/completed", item_id: tool });
        yield* emit({ type: "item/result", item_id: tool, content: "done" });
      }
    } else {
      const change = `${prefix}-change`;
      const patch = `${prefix}-patch`;
      yield* emit({
        type: "item/started",
        item_type: "tool_use",
        item_id: change,
        name: "fileChange",
        input: {
          changes: [
            { path: `${change}.md`, kind: { type: "add" }, diff: text },
          ],
        },
      });
      yield* emit({ type: "item/completed", item_id: change });
      yield* emit({
        type: "item/started",
        item_type: "tool_use",
        item_id: patch,
        name: "apply_patch",
        input: {
          input: `*** Begin Patch\n*** Update File: ${patch}.md\n@@ -1 +1 @@\n-old\n+${text}\n*** End Patch\n`,
        },
      });
      if (turn % 2 === 0)
        yield* emit({ type: "item/completed", item_id: patch });
    }

    const denied = `${prefix}-denied`;
    yield* emit({
      type: "item/started",
      item_type: "tool_use",
      item_id: denied,
      name: "Bash",
    });
    yield* emit({ type: "item/denied", item_id: denied, by: "settingsRule" });
    if (driver === "claude") {
      // Abandoned next to committed blocks: the message survives.
      const abandoned = `${prefix}-abandoned`;
      yield* emit({
        type: "item/started",
        item_type: "text",
        item_id: abandoned,
        text,
      });
      yield* emit({
        type: "item/delta",
        item_id: abandoned,
        delta_type: "text_delta",
        content: " discarded",
      });
      yield* emit({ type: "item/completed", item_id: abandoned });
      yield* emit({ type: "item/abandoned", item_id: abandoned });
    }
    yield* emit({ type: "agent/unrecognized", reason: "mid-turn data" });
    yield* emit({
      type: "agent/notice",
      severity: "warning",
      subject: "Notice",
      body: "Mid-turn notice",
    });
    yield* emit({
      type: "cydo/task_diagnostic",
      severity: "warning",
      subject: "Diagnostic",
      body: "Mid-turn diagnostic",
    });
    yield* emit({ type: "process/stderr", text: "stderr line 1" });
    yield* emit({ type: "process/stderr", text: "stderr line 2" });
    yield* emit({ type: "turn/delta", model: "updated-model", uuid: prefix });
    yield* emit({
      type: "turn/stop",
      uuid: prefix,
      history_boundary: { kind: "agent_turn", anchor: prefix },
    });
    yield* emit({
      type: "turn/result",
      subtype: "success",
      is_error: turn % 2 === 1,
      num_turns: 1,
      duration_ms: 10,
      total_cost_usd: 0.03,
      usage: { input_tokens: 10, output_tokens: 5 },
    });
    if (driver === "claude") {
      // Abandoned as the only block: the message is removed.
      const lone = `${prefix}-lone`;
      yield* emit({
        type: "item/started",
        item_type: "tool_use",
        item_id: lone,
        name: "Bash",
      });
      yield* emit({ type: "item/abandoned", item_id: lone });
      yield* emit({ type: "turn/stop", uuid: `${prefix}-capped` });
    }
    if (turn % 4 === 3) {
      yield* emit({
        type: "turn/retracted",
        uuids: [prefix],
        notice: {
          type: "cydo/task_diagnostic",
          severity: "warning",
          subject: "Retracted",
          body: "Retrying turn",
        },
      });
    }
  }
}
