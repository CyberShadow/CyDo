/** @vitest-environment jsdom */

import { h } from "preact";
import renderToString from "preact-render-to-string";
import { expect, it } from "vitest";
import { TaskOrigin } from "./TaskOrigin";

it.each([
  ["Parent task", "Created by “Parent task”"],
  [undefined, "Created by task 7"],
])("renders only the creator link for title %s", (title, label) => {
  const root = document.createElement("div");
  root.innerHTML = renderToString(
    h(TaskOrigin, { creator: { tid: 7, href: "/task/7", title } }),
  );
  const origin = root.querySelector(".task-origin")!;
  expect(origin.children).toHaveLength(1);
  const link = origin.querySelector("a");
  expect(link?.getAttribute("href")).toBe("/task/7");
  expect(link?.textContent).toContain(label);
  expect(origin.textContent).toBe(link?.textContent);
});
