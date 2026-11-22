import { render, type ComponentChild } from "preact";
import { act } from "preact/test-utils";
import { afterEach, expect } from "vitest";

// Own each jsdom root here or unmount it through act in a try/finally.
// While a root is mounted, await through act or an act-based helper. Trigger
// updates inside act, and keep dependent waits in one actPoll call.
// Assert before passive effects inside the same act callback as the update.

export function ownedRoots(): {
  create(): HTMLDivElement;
  render(vnode: ComponentChild, root: HTMLDivElement): void;
} {
  if (expect.getState().currentTestName !== undefined) {
    throw new Error("ownedRoots must be called during test collection");
  }

  const roots = new Set<HTMLDivElement>();

  afterEach(async () => {
    await act(() => {
      for (const root of roots) render(null, root);
    });
    for (const root of roots) root.remove();
    roots.clear();
  });

  return {
    create() {
      const root = document.createElement("div");
      document.body.appendChild(root);
      roots.add(root);
      return root;
    },
    render(vnode, root) {
      void act(() => {
        render(vnode, root);
      });
    },
  };
}

// Return act's promise directly so effects can flush without introducing
// another promise continuation before the next poll step.
export function actStep(update?: () => void): Promise<void> {
  return act(async () => {
    update?.();
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  });
}

export interface PollStage {
  description: string;
  ready(): boolean;
  steps?: number;
}

export async function actPoll(
  ...stages: [PollStage, ...PollStage[]]
): Promise<void> {
  for (const stage of stages) {
    const steps = stage.steps ?? 100;
    let used = 0;
    while (!stage.ready()) {
      if (used === steps) {
        throw new Error(`timed out waiting for ${stage.description}`);
      }
      used++;
      await actStep();
    }
  }
}
