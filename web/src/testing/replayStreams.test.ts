import { describe, expect, it } from "vitest";
import {
  reduceAgentAck,
  reduceMessage,
  rejectOrdinarySubmission,
  replaceHistoryBoundary,
} from "../sessionReducer";
import { replayInitialState, replayStream } from "./replayStreams";

type Driver = Parameters<typeof replayStream>[0];

function prefix(driver: Driver, seed: number) {
  const stream = replayStream(driver, seed);
  return Array.from({ length: 320 }, () => {
    const next = stream.next();
    if (next.done) throw new Error("Replay stream ended early");
    return next.value;
  });
}

const commonCases = [
  "session/init",
  "session/metadata",
  "item/started:user_message",
  "item/started:user_message:pending",
  "item/started:user_message:optimistic-echo",
  "item/started:user_message:pending-replay-echo",
  "item/completed:replaces-streamed-tool-text",
  "item/started:user_message:canonical-echo",
  "item/started:text",
  "item/started:thinking",
  "item/started:tool_use",
  "item/started:cydo Task",
  "item/started:sidechain",
  "item/delta:text_delta",
  "item/completed",
  "item/result",
  "item/denied",
  "turn/delta",
  "turn/stop:sidechain",
  "turn/stop",
  "turn/result:success",
  "turn/result:error",
  "task/started",
  "task/notification",
  "task/updated",
  "cydo/item_enriched",
  "cydo/item_enriched:spawned_child",
  "cydo/item_enriched:target_tid",
  "process/stderr:consecutive",
  "agent/unrecognized",
  "agent/notice",
  "cydo/task_diagnostic",
  "turn/retracted",
  "agent/command_output",
  "control/response",
  "session/cost",
  "user_message/consumed:steering",
  "user_message/consumed:removed",
  "user_message/consumed:cancelled",
  "user_message/consumed:canonical-follows",
];

describe.each(["claude", "codex"] as const)("%s replay stream", (driver) => {
  it.each([0, 42])("repeats its operations for seed %i", (seed) => {
    expect(prefix(driver, seed)).toEqual(prefix(driver, seed));
    expect(prefix(driver, seed)).not.toEqual(prefix(driver, seed + 1));
  });

  it("generates all required operations and driver-specific event cases", () => {
    const kinds = new Set<string>();
    const boundaries = new Set<string>();
    const cases = new Set<string>();
    const localNonces = new Set(
      replayInitialState(driver).messages.map((m) => m.nonce),
    );
    const pendingUuids = new Set<string>();
    const expectedNativeUuids = new Set<string>();
    const inputlessTools = new Set<string>();
    const streamedText = new Map<string, string>();
    let previousType: string | undefined;
    for (const operation of prefix(driver, 42)) {
      kinds.add(operation.kind);
      if (operation.kind === "boundary") {
        boundaries.add(operation.event.history_boundary!.kind);
      }
      if (operation.kind !== "event") continue;
      const { event } = operation;
      cases.add(event.type);
      switch (event.type) {
        case "cydo/item_enriched":
          if (event.spawned_child)
            cases.add("cydo/item_enriched:spawned_child");
          if (event.target_tid !== undefined)
            cases.add("cydo/item_enriched:target_tid");
          break;
        case "item/started":
          cases.add(`item/started:${event.item_type}`);
          if (event.name) cases.add(`tool:${event.name}`);
          if (event.item_type === "tool_use" && event.input === undefined)
            inputlessTools.add(event.item_id);
          if (event.name === "Task" && event.tool_server === "cydo")
            cases.add("item/started:cydo Task");
          if (event.item_type === "user_message") {
            if (event.pending && event.uuid) {
              pendingUuids.add(event.uuid);
              cases.add("item/started:user_message:pending");
            }
            if (
              event.is_replay &&
              event.correlation_id &&
              localNonces.has(event.correlation_id)
            ) {
              cases.add("item/started:user_message:optimistic-echo");
              if (event.pending)
                cases.add("item/started:user_message:pending-replay-echo");
            }
            if (
              event.is_replay &&
              event.uuid &&
              expectedNativeUuids.has(event.uuid)
            )
              cases.add("item/started:user_message:canonical-echo");
          }
          if (event.parent_tool_use_id && event.is_sidechain)
            cases.add("item/started:sidechain");
          break;
        case "item/delta":
          cases.add(`item/delta:${event.delta_type}`);
          if (event.delta_type === "text_delta") {
            streamedText.set(
              event.item_id,
              (streamedText.get(event.item_id) ?? "") + event.content,
            );
          }
          break;
        case "item/completed":
          if (
            inputlessTools.has(event.item_id) &&
            streamedText.has(event.item_id) &&
            event.input === undefined &&
            event.text !== undefined &&
            streamedText.get(event.item_id) !== event.text
          ) {
            cases.add("item/completed:replaces-streamed-tool-text");
          }
          break;
        case "item/result":
          if (
            event.tool_result &&
            typeof event.tool_result === "object" &&
            "bashEditDiff" in event.tool_result &&
            event.tool_result.bashEditDiff
          )
            cases.add("item/result:bashEditDiff");
          break;
        case "turn/stop":
          if (event.parent_tool_use_id && event.is_sidechain)
            cases.add("turn/stop:sidechain");
          break;
        case "turn/result":
          cases.add(
            event.is_error ? "turn/result:error" : "turn/result:success",
          );
          break;
        case "process/stderr":
          if (previousType === event.type)
            cases.add("process/stderr:consecutive");
          break;
        case "user_message/consumed":
          cases.add(`user_message/consumed:${event.consumed_as}`);
          if (
            event.consumed_as === "turn_start" &&
            event.native_uuid &&
            event.native_uuid !== event.uuid &&
            pendingUuids.has(event.uuid)
          ) {
            expectedNativeUuids.add(event.native_uuid);
            cases.add("user_message/consumed:canonical-follows");
          }
          break;
      }
      previousType = event.type;
    }
    expect(kinds).toEqual(new Set(["event", "boundary", "ack", "reject"]));
    expect(boundaries).toEqual(
      new Set(["user", "provisional_user", "agent_turn"]),
    );
    const driverCases =
      driver === "claude"
        ? [
            "item/abandoned",
            "item/permission",
            "item/delta:output_delta",
            "item/delta:stdin_delta",
            "tool:Edit",
            "tool:Write",
            "item/result:bashEditDiff",
          ]
        : ["tool:fileChange", "tool:apply_patch"];
    expect([...cases]).toEqual(
      expect.arrayContaining([...commonCases, ...driverCases]),
    );
  });

  it("replays through the reducer wrappers and renders diagnostics in their expected locations", () => {
    let state = replayInitialState(driver);
    const expectedParseErrors: number[] = [];
    const placements = new Set<string>();
    let spawnedMultipleSpecs = false;
    let enrichedBothFields = false;
    const abandonments = new Set<string>();
    let inlineBoundary: { event: unknown; seq: number } | undefined;
    for (const operation of prefix(driver, 42)) {
      if (operation.kind === "boundary" || inlineBoundary) {
        expect(inlineBoundary).toBeDefined();
        expect(operation).toEqual({ kind: "boundary", ...inlineBoundary });
      }
      inlineBoundary = undefined;
      switch (operation.kind) {
        case "event": {
          const { event, seq, ts } = operation;
          const streaming = state.messages.some(
            (m) => m.type === "assistant" && m.streaming,
          );
          if (
            event.type === "item/started" &&
            event.pending &&
            event.is_replay
          ) {
            const placeholder = state.messages.find(
              (message) =>
                message.isProvisional && message.nonce === event.correlation_id,
            );
            expect(placeholder).toMatchObject({ pending: true });
            state = reduceMessage(state, event, seq, ts);
            expect(
              state.messages.filter(
                (message) => message.id === placeholder!.id,
              ),
            ).toEqual([
              expect.objectContaining({
                uuid: event.uuid,
                pending: true,
                ackState: 3,
              }),
            ]);
          } else if (event.type === "cydo/item_enriched") {
            const key = state.itemIdMap.get(event.item_id)!;
            const previous = state.itemEnrichments.get(key);
            const previousSpecs = previous?.spawnedTids?.size ?? 0;
            state = reduceMessage(state, event, seq, ts);
            const enrichment = state.itemEnrichments.get(key);
            if (event.spawned_child) {
              const { spec_index, child_tid } = event.spawned_child;
              expect(enrichment?.spawnedTids?.size).toBe(previousSpecs + 1);
              expect(enrichment?.spawnedTids?.get(spec_index)).toBe(child_tid);
              spawnedMultipleSpecs ||= previousSpecs > 0;
              enrichedBothFields ||= previous?.targetTid !== undefined;
            }
            expect(enrichment?.targetTid).toBe(
              event.target_tid ?? previous?.targetTid,
            );
          } else if (event.type === "item/abandoned") {
            const key = state.itemIdMap.get(event.item_id)!;
            const owner = state.messages.find((message) =>
              message.blockIds?.includes(key),
            )!;
            state = reduceMessage(state, event, seq, ts);
            expect(state.blocks.has(key)).toBe(false);
            expect(state.itemIdMap.has(event.item_id)).toBe(false);
            const survivor = state.messages.find(({ id }) => id === owner.id);
            if (owner.blockIds!.length > 1) {
              expect(survivor?.blockIds).toEqual(
                owner.blockIds!.filter((id) => id !== key),
              );
              abandonments.add("block");
            } else {
              expect(survivor).toBeUndefined();
              abandonments.add("message");
            }
          } else {
            state = reduceMessage(state, event, seq, ts);
          }
          if ("history_boundary" in event && event.history_boundary)
            inlineBoundary = { event, seq };
          if (
            event.type === "agent/unrecognized" ||
            event.type === "agent/notice" ||
            event.type === "cydo/task_diagnostic"
          ) {
            const body =
              event.type === "agent/unrecognized" ? event.reason : event.body;
            const message = state.messages.find(({ seq: messageSeq }) =>
              Array.isArray(messageSeq)
                ? messageSeq.includes(seq)
                : messageSeq === seq,
            );
            if (streaming) {
              expect(message).toMatchObject({
                type: "assistant",
                streaming: true,
              });
              expect(
                message?.blockIds?.map((id) => state.blocks.get(id)),
              ).toContainEqual(
                expect.objectContaining({
                  type:
                    event.type === "agent/unrecognized"
                      ? "unrecognized"
                      : "diagnostic",
                  text: body,
                }),
              );
              placements.add(`${event.type}:mid-turn`);
            } else {
              if (event.type === "agent/unrecognized") {
                expectedParseErrors.push(seq);
                expect(message).toMatchObject({
                  type: "system",
                  subtype: "parse_error",
                  seq,
                  rawSource: event,
                });
              } else {
                expect(message).toMatchObject({
                  type: "diagnostic",
                  seq,
                  rawSource: event,
                });
              }
              placements.add(`${event.type}:top-level`);
            }
          }
          break;
        }
        case "boundary":
          state = replaceHistoryBoundary(state, operation.event, operation.seq);
          expect(state.replacementEvents.get(operation.seq)).toEqual(
            operation.event,
          );
          break;
        case "ack":
          state = reduceAgentAck(state, operation.nonce);
          expect(
            state.messages.find((m) => m.nonce === operation.nonce)?.ackState,
          ).toBe(2);
          break;
        case "reject":
          expect(state.messages.some((m) => m.nonce === operation.nonce)).toBe(
            true,
          );
          state = rejectOrdinarySubmission(state, operation.nonce);
          expect(state.messages.some((m) => m.nonce === operation.nonce)).toBe(
            false,
          );
          break;
      }
      expect(
        state.messages
          .filter((m) => m.subtype === "parse_error")
          .map((m) => m.seq),
      ).toEqual(expectedParseErrors);
    }
    expect(inlineBoundary).toBeUndefined();
    expect(spawnedMultipleSpecs).toBe(true);
    expect(enrichedBothFields).toBe(true);
    expect(abandonments).toEqual(
      new Set(driver === "claude" ? ["block", "message"] : []),
    );
    expect(placements).toEqual(
      new Set([
        "agent/unrecognized:top-level",
        "agent/unrecognized:mid-turn",
        "agent/notice:top-level",
        "agent/notice:mid-turn",
        "cydo/task_diagnostic:top-level",
        "cydo/task_diagnostic:mid-turn",
      ]),
    );
  });

  it("produces tracked file edits with the expected status transitions", () => {
    let state = replayInitialState(driver);
    const applied = new Set<string>();
    const completed = new Set<string>();
    const cancelled = new Set<string>();
    for (const operation of prefix(driver, 42)) {
      if (operation.kind !== "event") continue;
      const { event, seq, ts } = operation;
      const previousFiles = state.trackedFiles;
      state = reduceMessage(state, event, seq, ts);
      for (const [path, file] of state.trackedFiles) {
        for (const edit of file.edits) {
          if (edit.status === "applied")
            applied.add(`${edit.source}:${edit.op}`);
          const previous = previousFiles
            .get(path)
            ?.edits.find(
              (candidate) =>
                candidate.toolUseId === edit.toolUseId &&
                candidate.changeIndex === edit.changeIndex,
            );
          if (previous?.status !== "pending") continue;
          if (edit.status === "applied") {
            expect(event).toMatchObject({
              type: "item/completed",
              item_id: edit.toolUseId,
            });
            completed.add(`${edit.source}`);
          }
          if (edit.status === "cancelled") {
            expect(event).toMatchObject({
              type: "turn/result",
              is_error: true,
            });
            cancelled.add(`${edit.source}`);
          }
        }
      }
    }

    if (driver === "claude") {
      expect([...applied]).toEqual(
        expect.arrayContaining([
          "claude-tool:edit",
          "claude-tool:write",
          expect.stringMatching(/^claude-bashEditDiff:/),
        ]),
      );
    } else {
      expect(completed).toEqual(
        new Set(["codex-fileChange", "codex-apply_patch-history"]),
      );
      expect(cancelled).toEqual(new Set(["codex-apply_patch-history"]));
    }
  });
});
