import { render, type ComponentChild } from "preact";
import { act } from "preact/test-utils";
import { afterEach, expect, vi, type TestContext } from "vitest";
import { hangTimeout } from "./hangTimeout";

// Own each jsdom root here or unmount it through act in a try/finally.
// While a root is mounted, await through act or an act-based helper. Trigger
// updates inside act, and keep dependent waits in one actPoll call.
// Assert before passive effects inside the same act callback as the update.
// joinedRows waits for the test body to settle before cleanup. Keep global
// cleanup out of the body and use row.poll or row.signal for abortable waits.

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

export function actPoll(...stages: [PollStage, ...PollStage[]]): Promise<void> {
  return pollStages(undefined, ...stages);
}

async function pollStages(
  signal: AbortSignal | undefined,
  ...stages: [PollStage, ...PollStage[]]
): Promise<void> {
  for (const stage of stages) {
    const deadline = performance.now() + hangTimeout;
    let used = 0;
    for (;;) {
      signal?.throwIfAborted();
      const ready = stage.ready();
      signal?.throwIfAborted();
      if (ready) break;
      if (used === stage.steps || performance.now() >= deadline) {
        throw new Error(`timed out waiting for ${stage.description}`);
      }
      used++;
      await actStep();
    }
  }
}

export interface JoinedRow {
  root: HTMLDivElement;
  signal: AbortSignal;
  poll: (...stages: [PollStage, ...PollStage[]]) => Promise<void>;
}

export function joinedRows() {
  let active: { root: HTMLDivElement; settled: Promise<void> } | undefined;

  afterEach(async () => {
    if (!active) throw new Error("joinedRows: test did not call run");
    const { root, settled } = active;
    // Vitest can report a timeout while the test callback is still unwinding.
    await settled.catch(() => undefined);
    active = undefined;
    await act(() => {
      render(null, root);
    });
    root.remove();
    vi.restoreAllMocks();
  });

  return (context: TestContext, body: (row: JoinedRow) => Promise<void>) => {
    const { signal } = context;
    const root = document.createElement("div");
    document.body.appendChild(root);
    const settled = body({
      root,
      signal,
      poll: (...stages) => pollStages(signal, ...stages),
    });
    active = { root, settled };
    return settled;
  };
}
