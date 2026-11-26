import type { ImageAttachment } from "./draftReconciler";

export interface ControlledImageEntry {
  resetToken: number;
  generation: number;
  images: ImageAttachment[];
  refusals: readonly string[];
  listeners: Set<
    (
      images: ImageAttachment[],
      refusals: readonly string[],
      generation: number,
    ) => void
  >;
}

export interface ControlledImageStore {
  entries: Map<string, ControlledImageEntry>;
}

export function createControlledImageStore(): ControlledImageStore {
  return { entries: new Map() };
}

export function publishControlledImageEntry(
  entry: ControlledImageEntry,
  images: ImageAttachment[],
  refusals: readonly string[],
  notify = true,
) {
  entry.images = images;
  entry.refusals = refusals;
  if (notify) {
    for (const listener of entry.listeners) {
      listener(images, refusals, entry.generation);
    }
  }
}

export function invalidateControlledImageEntry(
  entry: ControlledImageEntry,
  notify = true,
) {
  entry.generation++;
  publishControlledImageEntry(entry, [], [], notify);
  entry.listeners.clear();
}

export function retireControlledImage(
  store: ControlledImageStore,
  key: string,
) {
  const entry = store.entries.get(key);
  if (!entry) return;
  store.entries.delete(key);
  invalidateControlledImageEntry(entry, false);
}

export function resetControlledImageStore(store: ControlledImageStore) {
  const entries = Array.from(store.entries.values());
  store.entries.clear();
  for (const entry of entries) {
    invalidateControlledImageEntry(entry);
  }
}
