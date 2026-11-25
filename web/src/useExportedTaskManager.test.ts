/** @vitest-environment jsdom */

import { h } from "preact";
import { describe, expect, it } from "vitest";
import type { AgnosticEvent } from "./protocol";
import { reduceMessage } from "./sessionReducer";
import { ownedRoots } from "./test-support/preactAct";
import { makeTaskState } from "./types";
import {
  parseExportDataText,
  useExportedTaskManager,
} from "./useExportedTaskManager";

describe("parseExportDataText", () => {
  it("returns a visible error when export payload is missing", () => {
    const parsed = parseExportDataText(null);
    expect(parsed.data).toBeNull();
    expect(parsed.error).toBe("Missing embedded export data.");
  });

  it("returns a visible error when export payload is invalid JSON", () => {
    const parsed = parseExportDataText("{bad json");
    expect(parsed.data).toBeNull();
    expect(parsed.error).toBe("Failed to parse embedded export data.");
  });

  it("accepts export payloads with tasks array", () => {
    const parsed = parseExportDataText('{"tasks":[{"tid":1}]}');
    expect(parsed.error).toBeNull();
    expect(parsed.data?.tasks).toHaveLength(1);
  });
});

describe("useExportedTaskManager", () => {
  const roots = ownedRoots();

  it("reconstructs the same task state as reducing each exported event in order", () => {
    const tid = 42;
    const events: AgnosticEvent[] = [
      {
        type: "item/started",
        item_type: "user_message",
        item_id: "user",
        content: [{ type: "text", text: "Hello" }],
      },
      {
        type: "item/started",
        item_type: "text",
        item_id: "reply",
        text: "Hi",
      },
      {
        type: "item/delta",
        item_id: "reply",
        delta_type: "text_delta",
        content: " there",
      },
      { type: "turn/stop" },
    ];
    const expected = events.reduce(
      (state, event, index) => reduceMessage(state, event, index, undefined),
      makeTaskState(
        tid,
        false,
        false,
        undefined,
        true,
        undefined,
        undefined,
        undefined,
        undefined,
        "completed",
      ),
    );

    const data = document.createElement("script");
    data.id = "cydo-export-data";
    data.type = "application/json";
    data.textContent = JSON.stringify({
      tasks: [{ tid }],
      events: {
        [tid]: events.map((event, index) => ({
          tid,
          seq: index + 100,
          ts: 1_700_000_000_000 + index,
          event,
        })),
      },
    });
    document.body.appendChild(data);
    let manager: ReturnType<typeof useExportedTaskManager> | undefined;
    function Probe() {
      manager = useExportedTaskManager();
      return null;
    }
    try {
      roots.render(h(Probe, {}), roots.create());
      const actual = manager?.getByTid(tid);
      // Each reconstruction generates a fresh task UUID.
      expect(actual).toEqual({
        ...expected,
        uuid: actual?.uuid,
      });
    } finally {
      data.remove();
    }
  });
});
