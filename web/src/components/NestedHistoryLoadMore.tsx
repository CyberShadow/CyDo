import { createContext } from "preact";
import { useContext } from "preact/hooks";
import { StatusBand } from "./StatusBand";

/** what an Agent call's block needs to offer the older part of its
 *  sub-agent's transcript, when a windowed replay held it back */
export interface NestedHistory {
  /** held-back transcripts, by the Agent call's tool use id */
  windows: ReadonlyMap<string, number> | undefined;
  /** configured window size in messages for this device class */
  step: number | undefined;
  /** transcripts with a batch on the way */
  loading: ReadonlySet<string>;
  /** load `step` more messages of that transcript; 0 = all */
  load: (parentToolUseId: string, step: number) => void;
}

export const NestedHistoryContext = createContext<NestedHistory | null>(null);

/** the load-more row at the top of a sub-agent's messages, while older ones
 *  are held back; the same buttons as the task's own */
export function NestedHistoryLoadMore({
  parentToolUseId,
}: {
  parentToolUseId: string;
}) {
  const nested = useContext(NestedHistoryContext);
  if (
    nested === null ||
    nested.step === undefined ||
    nested.step <= 0 ||
    !nested.windows?.has(parentToolUseId)
  )
    return null;
  const step = nested.step;
  return (
    <div class="load-more-row nested-load-more-row">
      {nested.loading.has(parentToolUseId) ? (
        <div class="load-more-loading" aria-label="Loading older messages">
          <StatusBand status="requesting" />
        </div>
      ) : (
        <>
          <button
            class="btn"
            onClick={() => {
              nested.load(parentToolUseId, step);
            }}
          >
            Load {step} more
          </button>
          <button
            class="btn"
            onClick={() => {
              nested.load(parentToolUseId, step * 5);
            }}
          >
            Load {step * 5} more
          </button>
          <button
            class="btn"
            onClick={() => {
              nested.load(parentToolUseId, 0);
            }}
          >
            Load all
          </button>
        </>
      )}
    </div>
  );
}
