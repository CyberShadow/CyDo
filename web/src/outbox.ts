// Per-browser outbox for unsent messages, stored in localStorage.
// Replayed on reconnect/reload to guarantee at-least-once delivery;
// the backend deduplicates via the nonce (correlation_id).

const STORAGE_KEY = "cydo.outbox.v1";

export interface OutboxEntry {
  tid: number;
  nonce: string;
  content: unknown;
  createdAt: number;
}

type Listener = () => void;
const listeners = new Set<Listener>();

function read(): OutboxEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as OutboxEntry[];
  } catch {
    return [];
  }
}

function write(entries: OutboxEntry[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entries));
  } catch (e) {
    console.warn("[outbox] localStorage write failed:", e);
  }
}

function notify(): void {
  for (const fn of listeners) fn();
}

export const outbox = {
  all(): OutboxEntry[] {
    return read();
  },

  add(entry: OutboxEntry): void {
    const entries = read().filter((e) => e.nonce !== entry.nonce);
    entries.push(entry);
    write(entries);
    notify();
  },

  remove(nonce: string): void {
    const entries = read().filter((e) => e.nonce !== nonce);
    write(entries);
    notify();
  },

  removeForTask(tid: number): void {
    const entries = read().filter((e) => e.tid !== tid);
    write(entries);
    notify();
  },

  byTid(tid: number): OutboxEntry[] {
    return read().filter((e) => e.tid === tid);
  },

  subscribe(fn: Listener): () => void {
    listeners.add(fn);
    return () => listeners.delete(fn);
  },
};
