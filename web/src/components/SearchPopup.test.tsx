/** @vitest-environment jsdom */

import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { makeTaskState, type TaskState } from "../types";
import { SearchPopup } from "./SearchPopup";

describe("SearchPopup task loading", () => {
  let container: HTMLDivElement;
  let scrollIntoView: PropertyDescriptor | undefined;

  const mount = (tasks: Map<string, TaskState>, tasksLoaded: boolean) => {
    const onSelect = vi.fn();
    const onClose = vi.fn();
    void act(() => {
      render(
        <SearchPopup
          tasks={tasks}
          tasksLoaded={tasksLoaded}
          taskTypes={[]}
          onSelect={onSelect}
          onClose={onClose}
          getTaskHref={(tid) => `/task/${tid}`}
        />,
        container,
      );
    });
    return { onSelect, onClose };
  };

  beforeEach(() => {
    scrollIntoView = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "scrollIntoView",
    );
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: () => {},
    });
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    void act(() => {
      render(null, container);
    });
    container.remove();
    if (scrollIntoView) {
      Object.defineProperty(
        HTMLElement.prototype,
        "scrollIntoView",
        scrollIntoView,
      );
    } else {
      delete (HTMLElement.prototype as { scrollIntoView?: unknown })
        .scrollIntoView;
    }
  });

  it("reports that more sessions are loading for an empty partial list", () => {
    mount(new Map(), false);

    expect(container.querySelector(".search-no-results")?.textContent).toBe(
      "More sessions are loading…",
    );
  });

  it("reports no matches only after the list is complete", () => {
    mount(new Map(), true);

    expect(container.querySelector(".search-no-results")?.textContent).toBe(
      "No matching sessions",
    );
  });

  it("shows known partial results immediately with their normal selection and link", () => {
    const task = {
      ...makeTaskState(17, false, false, "Known partial session"),
      lastActive: 10,
    };
    const { onSelect, onClose } = mount(new Map([[task.uuid, task]]), false);
    const result = container.querySelector<HTMLAnchorElement>(
      ".search-result-item",
    );

    expect(result?.textContent).toContain("Known partial session");
    expect(result?.classList.contains("selected")).toBe(true);
    expect(result?.getAttribute("href")).toBe("/task/17");
    const event = new MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      button: 0,
    });
    result?.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(onSelect).toHaveBeenCalledWith(17);
    expect(onClose).toHaveBeenCalledOnce();
  });
});
