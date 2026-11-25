/** @vitest-environment jsdom */

import { options, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ownedRoots } from "../test-support/preactAct";
import { makeTaskState, type TaskState } from "../types";
import { SearchPopup } from "./SearchPopup";

function makeTasks(
  count: number,
  options: {
    tid?: (index: number) => number;
    parentTid?: (index: number) => number | undefined;
    title?: (index: number) => string;
  } = {},
): Map<string, TaskState> {
  return new Map(
    Array.from({ length: count }, (_, index) => {
      const tid = options.tid?.(index) ?? index + 1;
      const task = {
        ...makeTaskState(
          tid,
          false,
          false,
          options.title?.(index) ?? `Task ${tid}`,
        ),
        uuid: `task-${tid}`,
        lastActive: index,
        parentTid: options.parentTid?.(index),
      };
      return [task.uuid, task];
    }),
  );
}

describe("SearchPopup", () => {
  const roots = ownedRoots();
  let container: HTMLDivElement;
  let scrollIntoView: PropertyDescriptor | undefined;

  const mount = (tasks: Map<string, TaskState>, tasksLoaded: boolean) => {
    const onSelect = vi.fn();
    const onClose = vi.fn();
    roots.render(
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
    return { onSelect, onClose };
  };

  const searchInput = () =>
    container.querySelector<HTMLInputElement>(".search-input")!;
  const checkbox = () =>
    container.querySelector<HTMLInputElement>(".search-option-checkbox")!;
  const resultLinks = () =>
    Array.from(container.querySelectorAll(".search-result-item"), (row) =>
      row.getAttribute("href"),
    );
  const selectedLink = () =>
    container
      .querySelector(".search-result-item.selected")
      ?.getAttribute("href");
  const overflow = () => container.querySelector<HTMLElement>(".search-more");

  const search = (query: string) => {
    void act(() => {
      const input = searchInput();
      input.value = query;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  };

  const keydown = (key: string, modifiers: KeyboardEventInit = {}) => {
    const event = new KeyboardEvent("keydown", {
      key,
      bubbles: true,
      cancelable: true,
      ...modifiers,
    });
    void act(() => {
      searchInput().dispatchEvent(event);
    });
    return event;
  };

  const parentAndChild = (childTid = 2) =>
    makeTasks(2, {
      tid: (index) => (index === 0 ? 1 : childTid),
      parentTid: (index) => (index === 0 ? undefined : 1),
    });

  beforeEach(() => {
    localStorage.clear();
    scrollIntoView = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "scrollIntoView",
    );
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: () => {},
    });
    container = roots.create();
  });

  afterEach(() => {
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

  it("shows the 99 most recent tasks and counts the remaining matches", () => {
    mount(makeTasks(150), true);

    expect(resultLinks()).toEqual(
      Array.from({ length: 99 }, (_, index) => `/task/${150 - index}`),
    );
    expect(overflow()?.textContent).toBe("…and 51 more");
    expect(overflow()?.hasAttribute("href")).toBe(false);
    expect(overflow()?.classList.contains("search-result-item")).toBe(false);
    expect(overflow()?.tabIndex).toBe(-1);
  });

  it("keeps keyboard and hover selection within the visible results", () => {
    const { onSelect } = mount(makeTasks(150), true);

    void act(() => {
      for (let i = 0; i < 150; i++) {
        searchInput().dispatchEvent(
          new KeyboardEvent("keydown", {
            key: "ArrowDown",
            bubbles: true,
            cancelable: true,
          }),
        );
      }
    });
    expect(selectedLink()).toBe("/task/52");

    void act(() => {
      overflow()!.dispatchEvent(new MouseEvent("mouseenter"));
    });
    expect(selectedLink()).toBe("/task/52");

    keydown("Enter");
    expect(onSelect).toHaveBeenCalledExactlyOnceWith(52);
  });

  it("hides sub-tasks by default", () => {
    mount(parentAndChild(), true);

    expect(resultLinks()).toEqual(["/task/1"]);
    expect(checkbox().checked).toBe(false);
  });

  it("persists checkbox changes across popup mounts and returns focus to search", () => {
    const tasks = parentAndChild();
    mount(tasks, true);

    void act(() => {
      // jsdom does not move focus when a checkbox or its label is clicked.
      checkbox().focus();
      checkbox().click();
    });
    expect(resultLinks()).toEqual(["/task/2", "/task/1"]);
    expect(localStorage.getItem("searchIncludeSubtasks")).toBe("true");
    expect(document.activeElement).toBe(searchInput());

    roots.render(null, container);
    mount(tasks, true);
    expect(checkbox().checked).toBe(true);
    expect(resultLinks()).toEqual(["/task/2", "/task/1"]);

    void act(() => {
      checkbox().focus();
      checkbox().labels![0]!.click();
    });
    expect(checkbox().checked).toBe(false);
    expect(resultLinks()).toEqual(["/task/1"]);
    expect(localStorage.getItem("searchIncludeSubtasks")).toBe("false");
    expect(document.activeElement).toBe(searchInput());
  });

  it("toggles with Alt+S by physical key and ignores extra modifiers", () => {
    mount(parentAndChild(), true);

    const shortcut = { altKey: true, code: "KeyS" };
    for (const extra of [
      { shiftKey: true },
      { ctrlKey: true },
      { metaKey: true },
    ]) {
      expect(keydown("s", { ...shortcut, ...extra }).defaultPrevented).toBe(
        false,
      );
      expect(checkbox().checked).toBe(false);
      expect(resultLinks()).toEqual(["/task/1"]);
    }

    expect(keydown("ß", shortcut).defaultPrevented).toBe(true);
    expect(checkbox().checked).toBe(true);
    expect(resultLinks()).toEqual(["/task/2", "/task/1"]);
  });

  it("finds an excluded sub-task only when its full task ID matches", () => {
    mount(parentAndChild(42), true);

    search("42");
    expect(resultLinks()).toEqual(["/task/42"]);

    search("4");
    expect(resultLinks()).toEqual([]);
  });

  it("pins the exact task ID ahead of newer partial matches when results are capped", () => {
    const tasks = makeTasks(151, {
      tid: (index) => (index === 0 ? 5 : index * 10 + 5),
      parentTid: (index) => (index === 0 ? 15 : undefined),
    });
    const { onSelect } = mount(tasks, true);

    search("5");
    expect(resultLinks()).toHaveLength(99);
    expect(resultLinks()[0]).toBe("/task/5");
    expect(overflow()?.textContent).toBe("…and 52 more");

    keydown("Enter");
    expect(onSelect).toHaveBeenCalledExactlyOnceWith(5);
  });

  it.each([
    {
      change: "typing a query",
      update: (input: HTMLInputElement) => {
        input.value = "5";
        input.dispatchEvent(new Event("input", { bubbles: true }));
      },
      firstTid: 5,
      links: [5, 25, 15],
    },
    {
      change: "toggling sub-tasks with Alt+S",
      update: (input: HTMLInputElement) => {
        input.dispatchEvent(
          new KeyboardEvent("keydown", { code: "KeyS", altKey: true }),
        );
      },
      firstTid: 25,
      links: [25, 15, 5],
    },
  ])(
    "selects the first result immediately after $change",
    ({ update, firstTid, links }) => {
      const { onSelect } = mount(
        makeTasks(3, {
          tid: (index) => 5 + index * 10,
          parentTid: (index) => (index === 0 ? 15 : undefined),
        }),
        true,
      );
      keydown("ArrowDown");
      expect(selectedLink()).toBe("/task/15");

      void act(() => {
        // Commit the updated results before act flushes passive effects.
        // eslint-disable-next-line @typescript-eslint/unbound-method
        const schedule = options.debounceRendering;
        let drain!: () => void;
        options.debounceRendering = (flush) => {
          drain = flush;
        };
        try {
          const input = searchInput();
          update(input);
          drain();
          expect(resultLinks()).toEqual(links.map((tid) => `/task/${tid}`));
          input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter" }));
          expect(onSelect).toHaveBeenCalledExactlyOnceWith(firstTid);
        } finally {
          options.debounceRendering = schedule;
        }
      });
    },
  );

  it("focuses the input during the render commit", () => {
    const previous = container.appendChild(document.createElement("textarea"));
    previous.focus();
    expect(document.activeElement).toBe(previous);
    const popupRoot = roots.create();

    // Direct render lets this assertion run before passive effects flush.
    render(
      <SearchPopup
        tasks={new Map()}
        tasksLoaded
        taskTypes={[]}
        onSelect={vi.fn()}
        onClose={vi.fn()}
        getTaskHref={(tid) => `/task/${tid}`}
      />,
      popupRoot,
    );

    expect(document.activeElement).toBe(
      popupRoot.querySelector(".search-input"),
    );
  });

  it("counts matches in a list of 50,000 tasks as the query crosses the cap", () => {
    const tasks = makeTasks(50_000, {
      parentTid: (index) =>
        index % 5 === 0 ? undefined : index - (index % 5) + 1,
      title: (index) => {
        if (index < 5 * 99) return "Review search";
        if (index < 5 * 100) return "Review storage";
        return "Build";
      },
    });
    mount(tasks, true);

    expect(resultLinks()).toHaveLength(99);
    expect(overflow()?.textContent).toBe("…and 9901 more");

    search("review");
    expect(resultLinks()).toHaveLength(99);
    expect(overflow()?.textContent).toBe("…and 1 more");

    search("review search");
    expect(resultLinks()).toHaveLength(99);
    expect(overflow()).toBeNull();
  });
});
