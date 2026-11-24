import type { DraftUpdatedMessage } from "./protocol";

export type OrdinaryDraftUpdate = Pick<
  DraftUpdatedMessage,
  "old_draft" | "new_draft"
>;

export type OrdinaryDraftListener = (text: string) => void;

export interface OrdinaryDraftStore {
  ensure(taskUuid: string, initialText: string): string;
  read(taskUuid: string): string | undefined;
  write(taskUuid: string, text: string): void;
  applyRemote(taskUuid: string, update: OrdinaryDraftUpdate): boolean;
  register(
    taskUuid: string,
    listener: OrdinaryDraftListener,
    onRetire?: () => void,
  ): () => void;
  retire(taskUuid: string): void;
  clear(): void;
}

type Entry = {
  text: string;
  listener: OrdinaryDraftListener | null;
  onRetire?: () => void;
};

export function createOrdinaryDraftStore(): OrdinaryDraftStore {
  const entries = new Map<string, Entry>();

  const entryFor = (taskUuid: string) => {
    const entry = entries.get(taskUuid);
    if (!entry) throw new Error(`Missing ordinary draft: ${taskUuid}`);
    return entry;
  };

  return {
    ensure(taskUuid, initialText) {
      const existing = entries.get(taskUuid);
      if (existing) return existing.text;
      entries.set(taskUuid, { text: initialText, listener: null });
      return initialText;
    },

    read(taskUuid) {
      return entries.get(taskUuid)?.text;
    },

    write(taskUuid, text) {
      const entry = entryFor(taskUuid);
      entry.text = text;
      entry.listener?.(text);
    },

    applyRemote(taskUuid, { old_draft, new_draft }) {
      const entry = entries.get(taskUuid) ?? {
        text: old_draft,
        listener: null,
      };
      entries.set(taskUuid, entry);
      if (entry.text !== "" && entry.text !== old_draft) return false;
      entry.text = new_draft;
      entry.listener?.(new_draft);
      return true;
    },

    register(taskUuid, listener, onRetire) {
      const entry = entryFor(taskUuid);
      if (entry.listener)
        throw new Error(`Ordinary draft already has a listener: ${taskUuid}`);
      entry.listener = listener;
      entry.onRetire = onRetire;
      listener(entry.text);
      return () => {
        if (entries.get(taskUuid) === entry && entry.listener === listener) {
          entry.listener = null;
          entry.onRetire = undefined;
        }
      };
    },

    retire(taskUuid) {
      const entry = entries.get(taskUuid);
      entries.delete(taskUuid);
      entry?.onRetire?.();
    },

    clear() {
      const retired = [...entries.values()];
      entries.clear();
      for (const entry of retired) entry.onRetire?.();
    },
  };
}
