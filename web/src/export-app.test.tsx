/** @vitest-environment jsdom */

import { render } from "preact";
import { act } from "preact/test-utils";
import { expect, it, vi } from "vitest";
import { ownedRoots } from "./test-support/preactAct";

vi.hoisted(() => {
  vi.stubGlobal("CSS", {
    supports: () => false,
    escape: (value: string) => value,
  });
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  }));
  HTMLElement.prototype.scrollIntoView = vi.fn();
});

import { ExportApp } from "./export-app";

const roots = ownedRoots();

it("styles a custom agent in the exported task bar using the stored driver", async () => {
  const data = document.createElement("script");
  data.id = "cydo-export-data";
  data.type = "application/json";
  data.textContent = JSON.stringify({
    tasks: [{ tid: 42, agent_name: "work-claude", driver: "claude" }],
  });
  roots.create().appendChild(data);

  const root = roots.create();
  await act(() => {
    render(<ExportApp />, root);
  });

  const agentChip = root.querySelector(".task-bar-agent");
  expect(agentChip?.textContent).toBe("work-claude");
  expect(agentChip?.getAttribute("data-driver")).toBe("claude");
});
