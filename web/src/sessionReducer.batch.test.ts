import { describe, expect, it } from "vitest";
import {
  reduceAgentAck,
  reduceAgentAckIn,
  reduceMessage,
  reduceMessageIn,
  rejectOrdinarySubmission,
  rejectOrdinarySubmissionIn,
  replaceHistoryBoundary,
  replaceHistoryBoundaryIn,
} from "./sessionReducer";
import { deepFreeze } from "./testing/deepFreeze";
import {
  replayInitialState,
  replayStream,
  type ReplayOperation,
} from "./testing/replayStreams";
import { makeTaskState, type TaskState } from "./types";
import { WriteBatch } from "./writeBatch";

type Driver = Parameters<typeof replayStream>[0];

function apply(state: TaskState, op: ReplayOperation, batch?: WriteBatch) {
  switch (op.kind) {
    case "event":
      return batch
        ? reduceMessageIn(batch, state, op.event, op.seq, op.ts)
        : reduceMessage(state, op.event, op.seq, op.ts);
    case "boundary":
      return batch
        ? replaceHistoryBoundaryIn(batch, state, op.event, op.seq)
        : replaceHistoryBoundary(state, op.event, op.seq);
    case "ack":
      return batch
        ? reduceAgentAckIn(batch, state, op.nonce)
        : reduceAgentAck(state, op.nonce);
    case "reject":
      return batch
        ? rejectOrdinarySubmissionIn(batch, state, op.nonce)
        : rejectOrdinarySubmission(state, op.nonce);
  }
}

function prefix(driver: Driver, seed: number, count: number) {
  const stream = replayStream(driver, seed);
  return Array.from(
    { length: count },
    () => stream.next().value as ReplayOperation,
  );
}

function serialize(state: TaskState) {
  return JSON.stringify(state, (_key, value: unknown) =>
    value instanceof Map ? [...value] : value,
  );
}

function checkStreamingMessageCount(state: TaskState, context: string) {
  expect(state.streamingMessageCount, context).toBe(
    state.messages.filter(
      (message) => message.type === "assistant" && message.streaming === true,
    ).length,
  );
}

function checkSeqOwnership(state: TaskState, operation: number) {
  const owners = new Map<number, number>();
  for (const [index, message] of state.messages.entries()) {
    if (message.seq === undefined) continue;
    const seqs = Array.isArray(message.seq) ? message.seq : [message.seq];
    for (const seq of seqs) {
      const owner = owners.get(seq);
      if (owner !== undefined && owner !== index) {
        throw new Error(
          `After operation ${operation}, seq ${seq} belongs to messages at indices ${owner} and ${index}`,
        );
      }
      owners.set(seq, index);
    }
  }
}

function checkIdentity(
  before: unknown,
  reference: unknown,
  actual: unknown,
  path: string,
): void {
  if (typeof before !== "object" || before === null) return;

  const kept = reference === before;
  const actualKept = actual === before;
  if (kept !== actualKept) expect(actualKept, path).toBe(kept);
  if (kept) return;

  if (
    before instanceof Map &&
    reference instanceof Map &&
    actual instanceof Map
  ) {
    expect([...actual.keys()], path).toEqual([...reference.keys()]);
    for (const key of before.keys() as MapIterator<unknown>) {
      if (reference.has(key)) {
        checkIdentity(
          before.get(key),
          reference.get(key),
          actual.get(key),
          `${path}[${String(key)}]`,
        );
      }
    }
  } else if (
    reference !== null &&
    typeof reference === "object" &&
    actual !== null &&
    typeof actual === "object"
  ) {
    const previous = before as Record<string, unknown>;
    const next = actual as Record<string, unknown>;
    const expected = reference as Record<string, unknown>;
    for (const key of Object.keys(previous)) {
      if (key === "messages" && path === "state") continue;
      checkIdentity(previous[key], expected[key], next[key], `${path}.${key}`);
    }
  }
}

function checkStateIdentity(
  before: TaskState,
  reference: TaskState,
  actual: TaskState,
) {
  checkIdentity(before, reference, actual, "state");
  expect(actual.messages === before.messages, "state.messages").toBe(
    reference.messages === before.messages,
  );
  const referenceById = new Map(
    reference.messages.map((message) => [message.id, message]),
  );
  const actualById = new Map(
    actual.messages.map((message) => [message.id, message]),
  );
  expect([...actualById.keys()], "state.messages IDs").toEqual([
    ...referenceById.keys(),
  ]);
  for (const message of before.messages) {
    if (referenceById.has(message.id)) {
      checkIdentity(
        message,
        referenceById.get(message.id),
        actualById.get(message.id),
        `state.messages[${message.id}]`,
      );
    }
  }
}

function randomSize(seed: number) {
  return () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return 1 + ((seed >>> 16) % 35);
  };
}

const splittings = [
  { name: "one batch", size: () => () => Infinity },
  ...[2, 3, 7, 35].map((size) => ({
    name: `batches of ${size}`,
    size: () => () => size,
  })),
  ...[11, 23, 47].map((seed) => ({
    name: `random batches (seed ${seed})`,
    size: () => randomSize(seed),
  })),
];

function checkBatches(
  initial: TaskState,
  operations: ReplayOperation[],
  size: () => number,
) {
  deepFreeze(operations);
  const expected = operations.reduce((state, op, i) => {
    const next = apply(state, op);
    checkStreamingMessageCount(next, `Unbatched operation ${i + 1}`);
    return next;
  }, initial);
  let state = initial;
  for (let start = 0; start < operations.length; ) {
    const end = Math.min(start + size(), operations.length);
    const input = deepFreeze(state);
    const serializedInput = serialize(input);
    const batch = new WriteBatch();
    let reference = input;
    for (let i = start; i < end; i++) {
      reference = apply(reference, operations[i]!);
      state = apply(state, operations[i]!, batch);
      checkSeqOwnership(reference, i + 1);
      checkSeqOwnership(state, i + 1);
      checkStreamingMessageCount(reference, `Reference operation ${i + 1}`);
      checkStreamingMessageCount(state, `Batched operation ${i + 1}`);
    }
    batch.close();
    expect(serialize(input), `input to operations ${start + 1}–${end}`).toBe(
      serializedInput,
    );
    checkStateIdentity(input, reference, state);
    expect(serialize(state), `output of operations ${start + 1}–${end}`).toBe(
      serialize(reference),
    );
    start = end;
  }
  expect(serialize(state)).toBe(serialize(expected));
}

const readA = {
  type: "item/started",
  item_type: "tool_use",
  item_id: "read-a",
  name: "Read",
} as const;
const readB = { ...readA, item_id: "read-b" };
const resultA = {
  type: "item/result",
  item_id: "read-a",
  content: [{ type: "text", text: "image result" }],
} satisfies Parameters<typeof reduceMessage>[1];
const companion = {
  type: "item/started",
  item_type: "user_message",
  item_id: "cc-user-msg",
  uuid: "image-companion",
  is_meta: true,
  content: [{ type: "text", text: "[Image: original 2400x2400]" }],
} satisfies Parameters<typeof reduceMessage>[1];
const stop = {
  type: "turn/stop",
  uuid: "X",
  history_boundary: { kind: "agent_turn", anchor: "X" },
} satisfies Parameters<typeof reduceMessage>[1];
const turnResult = {
  type: "turn/result",
  subtype: "success",
  is_error: false,
  num_turns: 1,
  duration_ms: 10,
  total_cost_usd: 0.03,
  usage: { input_tokens: 10, output_tokens: 5 },
} satisfies Parameters<typeof reduceMessage>[1];

function completedTurn() {
  const streaming = reduceMessage(makeTaskState(1), readA, 1);
  return deepFreeze(reduceMessage(streaming, stop, 2));
}

it("leaves a completed turn unchanged when another turn stop arrives", () => {
  const state = completedTurn();

  expect(state.streamingMessageCount).toBe(0);
  expect(reduceMessage(state, stop, 3)).toBe(state);
});

it("appends the result after an already completed turn", () => {
  const state = completedTurn();
  const output = reduceMessage(state, turnResult, 3);

  expect(output.streamingMessageCount).toBe(0);
  expect(output.messages).toHaveLength(2);
  expect(output.messages[0]).toBe(state.messages[0]);
  expect(output.messages[1]).toMatchObject({
    type: "result",
    seq: 3,
    resultData: { subtype: "success", isError: false },
  });
});

it("throws when the count is positive but no assistant is streaming", () => {
  const state = { ...completedTurn(), streamingMessageCount: 1 };

  expect(() => reduceMessage(state, stop, 3)).toThrow(
    "Streaming message count is inconsistent",
  );
});

it("leaves a streaming assistant alone when a different subagent stops", () => {
  const state = deepFreeze(
    reduceMessage(
      makeTaskState(1),
      { ...readA, parent_tool_use_id: "streaming-subagent" },
      1,
    ),
  );

  expect(state.streamingMessageCount).toBe(1);
  expect(
    reduceMessage(state, { ...stop, parent_tool_use_id: "other-subagent" }, 2),
  ).toBe(state);
});

const imageCompanionStreams = [
  {
    name: "interleaved image companion",
    events: [
      readA,
      { type: "item/completed", item_id: "read-a" },
      resultA,
      companion,
      readB,
      { type: "item/completed", item_id: "read-b" },
      stop,
    ],
  },
  {
    name: "image companion before a prompt",
    events: [
      readA,
      companion,
      stop,
      {
        type: "item/started",
        item_type: "user_message",
        item_id: "cc-user-msg",
        uuid: "next-prompt",
      },
    ],
  },
  {
    name: "image companion before a refusal",
    events: [
      readA,
      companion,
      stop,
      {
        type: "turn/retracted",
        uuids: ["other-message"],
        notice: {
          type: "cydo/task_diagnostic",
          severity: "warning",
          subject: "Model refused; switched",
          body: "Using fallback",
        },
      },
    ],
  },
] satisfies { name: string; events: Parameters<typeof reduceMessage>[1][] }[];

function copiedEntries(
  driver: Driver,
  operations: ReplayOperation[],
  size: number,
) {
  let state = replayInitialState(driver);
  let copied = 0;
  for (let start = 0; start < operations.length; start += size) {
    const batch = new WriteBatch();
    for (let i = start; i < Math.min(start + size, operations.length); i++) {
      state = apply(state, operations[i]!, batch);
    }
    copied += batch.copiedEntries;
    batch.close();
  }
  return copied;
}

describe.each(["claude", "codex"] as const)("%s reducer replay", (driver) => {
  describe.each([1, 17, 983])("stream seed %i", (seed) => {
    it.each(splittings)(
      "preserves state and identity with $name",
      ({ size }) => {
        checkBatches(
          replayInitialState(driver),
          prefix(driver, seed, 256),
          size(),
        );
      },
    );
  });

  it("copies linearly across a whole replay", () => {
    const n = 1_000;
    const large = prefix(driver, 17, 10 * n);
    const small = large.slice(0, n);

    expect(copiedEntries(driver, large, large.length)).toBeLessThanOrEqual(
      12 * Math.max(copiedEntries(driver, small, small.length), n),
    );
    expect(copiedEntries(driver, large, 1)).toBeGreaterThan(
      50 * copiedEntries(driver, small, 1),
    );
  }, 30_000);
});

describe.each(imageCompanionStreams)("$name", ({ events }) => {
  it.each(splittings)("preserves state and identity with $name", ({ size }) => {
    const initial = {
      ...makeTaskState(1),
      sessionInfo: {
        model: "claude-sonnet",
        version: "1.0.0",
        sessionId: "sid-1",
        cwd: "/tmp/project",
        tools: [],
        permission_mode: "default",
        supports_file_revert: false,
      },
    };
    const operations: ReplayOperation[] = events.map((event, i) => ({
      kind: "event",
      event,
      seq: i + 1,
      ts: 1_700_000_000_000 + i,
    }));
    checkBatches(initial, operations, size());
  });
});

it("returns the original state for a batch of no-ops", () => {
  const input = deepFreeze(replayInitialState("claude"));
  const batch = new WriteBatch();
  const output = reduceMessageIn(batch, input, {
    type: "item/delta",
    item_id: "unknown-item",
    delta_type: "text_delta",
    content: "ignored",
  });
  const afterAck = reduceAgentAckIn(batch, output, "unknown-nonce");
  const afterReject = rejectOrdinarySubmissionIn(
    batch,
    afterAck,
    "unknown-nonce",
  );
  batch.close();
  expect(output).toBe(input);
  expect(afterAck).toBe(input);
  expect(afterReject).toBe(input);
});

it("allocates a message ID without mutating the wrapper input", () => {
  const input = deepFreeze(makeTaskState(1));
  const counter = input.msgIdCounter;
  const output = reduceMessage(input, readA, 1);
  expect(output.msgIdCounter).toBe(counter + 1);
  expect(output.messages).toHaveLength(1);
  expect(input.msgIdCounter).toBe(counter);
});

it("keeps the counter current across top-level diagnostic messages", () => {
  const input = deepFreeze(makeTaskState(1));
  const notice = {
    type: "agent/notice",
    severity: "warning",
    subject: "Notice",
    body: "Generated notice",
  } as const;
  const first = reduceMessage(input, notice, 1);
  const second = reduceMessage(deepFreeze(first), notice, 2);

  expect(second.messages.map((message) => message.id)).toEqual([
    `task-diagnostic-${input.msgIdCounter + 1}`,
    `task-diagnostic-${input.msgIdCounter + 2}`,
  ]);
  for (const message of second.messages) {
    expect(second.msgIdCounter).toBeGreaterThanOrEqual(
      Number(message.id.slice(message.id.lastIndexOf("-") + 1)),
    );
  }
});

it("parses the streamed tool input before replacing the completed text", () => {
  const input = deepFreeze(makeTaskState(1));
  const batch = new WriteBatch();
  const events = [
    readA,
    {
      type: "item/delta",
      item_id: readA.item_id,
      delta_type: "text_delta",
      content: '{"file_path":"original"}',
    },
    {
      type: "item/completed",
      item_id: readA.item_id,
      text: '{"file_path":"replacement"}',
    },
  ] satisfies Parameters<typeof reduceMessage>[1][];
  const output = events.reduce(
    (state, event) => reduceMessageIn(batch, state, event),
    input,
  );
  batch.close();
  const id = output.itemIdMap.get(readA.item_id)!;

  expect(output.blocks.get(id)).toMatchObject({
    completed: true,
    input: { file_path: "original" },
    text: '{"file_path":"replacement"}',
  });
});
