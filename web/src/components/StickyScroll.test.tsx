/** @vitest-environment jsdom */
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { StickyScroll } from "./StickyScroll";

const root = document.createElement("div");

afterEach(async () => {
  await act(() => {
    render(null, root);
  });
  vi.unstubAllGlobals();
});

async function mount() {
  const callbacks = new Map<Element, () => void>();
  vi.stubGlobal(
    "ResizeObserver",
    class {
      constructor(private callback: () => void) {}
      observe(element: Element) {
        callbacks.set(element, this.callback);
      }
      disconnect() {
        callbacks.clear();
      }
    },
  );
  await act(() => {
    render(<StickyScroll as="div">Output</StickyScroll>, root);
  });

  const frame = root.firstElementChild as HTMLElement;
  const content = frame.firstElementChild!;
  let height = 300;
  let viewport = 100;
  let top = 0;
  Object.defineProperties(frame, {
    clientHeight: { get: () => viewport },
    scrollHeight: { get: () => height },
    scrollTop: {
      get: () => top,
      set: (value: number) => {
        top = Math.min(value, height - viewport);
      },
    },
  });
  callbacks.get(frame)?.();

  const resizeContent = () => callbacks.get(content)?.();
  return {
    frame,
    resizeContent,
    scrollTo: (value: number) => {
      frame.scrollTop = value;
      frame.dispatchEvent(new Event("scroll"));
    },
    growContent: (notify = true) => {
      height += 100;
      if (notify) resizeContent();
    },
    shrinkViewport: () => {
      viewport = 50;
      callbacks.get(frame)?.();
    },
  };
}

it("follows growing content from the bottom", async () => {
  const { frame, growContent } = await mount();
  expect(frame.scrollTop).toBe(200);
  growContent();
  expect(frame.scrollTop).toBe(300);
});

it("keeps following when a queued scroll arrives before the content resize", async () => {
  const { frame, growContent, resizeContent } = await mount();
  growContent(false);
  frame.dispatchEvent(new Event("scroll"));
  resizeContent();
  expect(frame.scrollTop).toBe(300);
});

it("leaves the scroll position alone after the reader scrolls up", async () => {
  const { frame, scrollTo, growContent } = await mount();
  scrollTo(100);
  growContent();
  expect(frame.scrollTop).toBe(100);
});

it("resumes following when the reader returns to the bottom", async () => {
  const { frame, scrollTo, growContent } = await mount();
  scrollTo(100);
  growContent();
  scrollTo(300);
  growContent();
  expect(frame.scrollTop).toBe(400);
});

it("pins a following frame when its viewport shrinks", async () => {
  const { frame, shrinkViewport } = await mount();
  shrinkViewport();
  expect(frame.scrollTop).toBe(250);
});
