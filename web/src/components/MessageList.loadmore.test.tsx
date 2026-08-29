/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 *
 * Clicking a "Load [N] more" button gave no feedback at all until the slice
 * landed; the buttons must swap for the loading line immediately, and come
 * back (or disappear) once the window start moves.
 */
import { describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { act } from "preact/test-utils";
import { MessageList } from "./MessageList";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

function mount(
  container: HTMLElement,
  windowStart: number,
  onLoadMoreHistory: (step: number) => void,
) {
  render(
    <MessageList
      taskTid={1}
      messages={[]}
      replacementEvents={new Map()}
      blocks={new Map()}
      isProcessing={false}
      bandStatus=""
      onUndo={() => {}}
      historyWindowStart={windowStart}
      historyWindowStep={30}
      historyWindowed={true}
      onLoadMoreHistory={onLoadMoreHistory}
    />,
    container,
  );
}

describe("load-more loading feedback", () => {
  it("swaps the buttons for the loading line until the slice lands", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const calls: number[] = [];
    await act(() => {
      mount(container, 30, (step) => calls.push(step));
    });

    expect(container.querySelectorAll(".load-more-row .btn")).toHaveLength(3);
    expect(container.querySelector(".load-more-loading")).toBeNull();

    await act(() => {
      container
        .querySelector<HTMLButtonElement>(".load-more-row .btn")!
        .dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });

    expect(calls).toEqual([30]);
    expect(container.querySelectorAll(".load-more-row .btn")).toHaveLength(0);
    expect(container.querySelector(".load-more-loading")).not.toBeNull();

    // the slice landed: the window start moved, older history remains
    await act(() => {
      mount(container, 10, (step) => calls.push(step));
    });
    expect(container.querySelector(".load-more-loading")).toBeNull();
    expect(container.querySelectorAll(".load-more-row .btn")).toHaveLength(3);
  });
});
