/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { options, render } from "preact";
import { act } from "preact/test-utils";
import { InputBox } from "./InputBox";
import {
  createOrdinaryDraftStore,
  type OrdinaryDraftStore,
} from "../ordinaryDraftStore";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

const SESSION = "session-uuid";
const RECOVERED = 'Please reply with "CODEX_ROLLBACK_DEAD"';
const TYPED =
  "Reply exactly with CODEX_FALLBACK_RESPONSE. CODEX_FALLBACK_PROMPT";

function actSync(update: () => void) {
  // Preact flushes synchronous callbacks before returning from act.
  void act(update);
}

// Keep assertions that previously ran after the render queue, but before
// paint, inside act so passive hydration cannot mask a missed store delivery.
function actBeforePaint(update: () => void, assert: () => void) {
  actSync(() => {
    // Preact calls this scheduler as a standalone function.
    // eslint-disable-next-line @typescript-eslint/unbound-method
    const schedule = options.debounceRendering;
    let drain = () => {};
    options.debounceRendering = (render) => {
      drain = render;
    };
    try {
      update();
      drain();
      assert();
    } finally {
      options.debounceRendering = schedule;
    }
  });
}

function fill(textarea: HTMLTextAreaElement, value: string) {
  textarea.value = value;
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
}

interface MountOptions {
  sessionId?: string;
  serverDraft?: string;
  inputDraft?: string;
  onSaveDraft?: (draft: string) => void;
}

function ordinaryInput(
  store: OrdinaryDraftStore,
  sent: string[],
  options: MountOptions = {},
) {
  return (
    <InputBox
      onSend={(text) => {
        sent.push(text);
      }}
      onInterrupt={() => {}}
      isProcessing={false}
      disabled={false}
      sessionId={options.sessionId ?? SESSION}
      serverDraft={options.serverDraft}
      inputDraft={options.inputDraft}
      onInputDraftConsumed={() => {}}
      ordinaryDraftStore={store}
      onSaveDraft={options.onSaveDraft}
    />
  );
}

describe("recovered input draft vs. a concurrently typed message", () => {
  let container: HTMLDivElement;
  let sent: string[];
  let store: OrdinaryDraftStore;

  const mount = (inputDraft?: string) => {
    render(ordinaryInput(store, sent, { inputDraft }), container);
  };
  const textarea = () =>
    container.querySelector<HTMLTextAreaElement>("textarea")!;
  const sendButton = () =>
    container.querySelector<HTMLButtonElement>(".btn-send")!;

  beforeEach(() => {
    store = createOrdinaryDraftStore();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    actSync(() => {
      render(null, container);
    });
    container.remove();
  });

  it("keeps typed text when recovery and input arrive in the same frame", () => {
    actSync(() => {
      mount();
    });
    actSync(() => {
      mount(RECOVERED);
      fill(textarea(), TYPED);
    });

    expect(textarea().value).toBe(TYPED);
    expect(store.read(SESSION)).toBe(TYPED);
    actSync(() => {
      sendButton().click();
    });
    expect(sent).toEqual([TYPED]);
  });
});

describe("ordinary draft scalar delivery", () => {
  let container: HTMLDivElement;
  let sent: string[];
  let store: OrdinaryDraftStore;

  const mount = (serverDraft?: string, sessionId = SESSION) => {
    render(ordinaryInput(store, sent, { serverDraft, sessionId }), container);
  };
  const textarea = () =>
    container.querySelector<HTMLTextAreaElement>("textarea")!;
  const sendButton = () =>
    container.querySelector<HTMLButtonElement>(".btn-send")!;

  beforeEach(() => {
    store = createOrdinaryDraftStore();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    actSync(() => {
      render(null, container);
    });
    container.remove();
  });

  it("applies same-frame A to B to C transitions in order", () => {
    actBeforePaint(
      () => {
        mount("A");
        store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
        store.applyRemote(SESSION, { old_draft: "B", new_draft: "C" });
      },
      () => {
        expect(store.read(SESSION)).toBe("C");
        expect(textarea().value).toBe("C");
      },
    );
  });

  it("applies a same-frame clear after an accepted peer update", () => {
    actBeforePaint(
      () => {
        mount("A");
        store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
        store.applyRemote(SESSION, { old_draft: "B", new_draft: "" });
      },
      () => {
        expect(store.read(SESSION)).toBe("");
        expect(textarea().value).toBe("");
      },
    );
  });

  it("accepts sender-excluded non-contiguous compare-and-swap updates", () => {
    actBeforePaint(
      () => {
        mount("A");
        store.write(SESSION, "A");
        store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
        store.write(SESSION, "B");
        store.applyRemote(SESSION, { old_draft: "B", new_draft: "C" });
      },
      () => {
        expect(textarea().value).toBe("C");
      },
    );
  });

  it("preserves a locally divergent draft", () => {
    actSync(() => {
      mount("server text");
      fill(textarea(), "local text");
    });
    actSync(() => {
      store.applyRemote(SESSION, {
        old_draft: "server text",
        new_draft: "peer text",
      });
    });

    expect(store.read(SESSION)).toBe("local text");
    expect(textarea().value).toBe("local text");
  });

  it("flushes the current draft on pagehide", () => {
    const saved: string[] = [];
    actSync(() => {
      render(
        ordinaryInput(store, sent, {
          onSaveDraft: (draft) => {
            saved.push(draft);
          },
        }),
        container,
      );
    });
    actSync(() => {
      fill(textarea(), "draft typed before reload");
      window.dispatchEvent(new window.Event("pagehide"));
      expect(saved).toEqual(["draft typed before reload"]);
    });
  });

  it("does not resurrect a submitted draft on pagehide", () => {
    const saved: string[] = [];
    actSync(() => {
      render(
        ordinaryInput(store, sent, {
          onSaveDraft: (draft) => {
            saved.push(draft);
          },
        }),
        container,
      );
    });
    actSync(() => {
      fill(textarea(), "submitted draft");
    });
    actSync(() => {
      sendButton().click();
    });
    actSync(() => {
      window.dispatchEvent(new window.Event("pagehide"));
      expect(saved).toEqual([""]);
    });
  });

  it("preserves absent-composer compare-and-swap results across remount", () => {
    store.ensure("blank", "");
    store.ensure("equal", "A");
    store.ensure("divergent", "local");
    store.applyRemote("blank", { old_draft: "A", new_draft: "B" });
    store.applyRemote("equal", { old_draft: "A", new_draft: "B" });
    store.applyRemote("divergent", { old_draft: "A", new_draft: "B" });

    actSync(() => {
      mount(undefined, "blank");
      expect(textarea().value).toBe("B");
      render(null, container);
      mount(undefined, "equal");
      expect(textarea().value).toBe("B");
      render(null, container);
      mount(undefined, "divergent");
      expect(textarea().value).toBe("local");
    });
  });

  it("reflects controls before render, between render and layout, and after registration", () => {
    store.applyRemote("before", { old_draft: "A", new_draft: "B" });
    actSync(() => {
      mount(undefined, "before");
      expect(textarea().value).toBe("B");
      render(null, container);
    });

    const betweenStore = createOrdinaryDraftStore();
    actBeforePaint(
      () => {
        render(
          <>
            {ordinaryInput(betweenStore, sent, {
              sessionId: "between",
              serverDraft: "A",
            })}
            <RemoteUpdate
              store={betweenStore}
              sessionId="between"
              oldDraft="A"
              newDraft="B"
            />
          </>,
          container,
        );
      },
      () => {
        expect(textarea().value).toBe("B");
      },
    );

    actSync(() => {
      render(null, container);
    });
    const afterStore = createOrdinaryDraftStore();
    actBeforePaint(
      () => {
        render(
          ordinaryInput(afterStore, sent, {
            sessionId: "after",
            serverDraft: "A",
          }),
          container,
        );
        afterStore.applyRemote("after", { old_draft: "A", new_draft: "B" });
      },
      () => {
        expect(textarea().value).toBe("B");
      },
    );
  });
});

function RemoteUpdate({
  store,
  sessionId,
  oldDraft,
  newDraft,
}: {
  store: OrdinaryDraftStore;
  sessionId: string;
  oldDraft: string;
  newDraft: string;
}) {
  store.applyRemote(sessionId, { old_draft: oldDraft, new_draft: newDraft });
  return null;
}
