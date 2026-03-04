// Browser notifications for session state transitions (completion / awaiting input).
// Fires only when the tab is hidden. Also tracks which sessions need attention
// (awaiting input) so the sidebar can highlight them.

import { useEffect, useRef, useState, useCallback } from "preact/hooks";
import type { SessionState } from "./types";

interface Snapshot {
  alive: boolean;
  isProcessing: boolean;
}

function lastMessageText(s: SessionState): string {
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const msg = s.messages[i];
    if (msg.type === "result" || msg.type === "compact_boundary") continue;
    for (const block of msg.content) {
      if (block.type === "text" && block.text) {
        const trimmed = block.text.trim();
        if (trimmed)
          return trimmed.length > 200 ? trimmed.slice(0, 200) + "…" : trimmed;
      }
    }
  }
  return "";
}

export function useNotifications(
  sessions: Map<number, SessionState>,
  activeSessionId: number | null,
) {
  const prevRef = useRef<Map<number, Snapshot>>(new Map());
  const [attention, setAttention] = useState<Set<number>>(new Set());

  // Request permission once on mount
  useEffect(() => {
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission();
    }
  }, []);

  // Clear attention for the active session when tab is visible
  useEffect(() => {
    if (activeSessionId === null) return;

    const clear = () => {
      if (!document.hidden) {
        setAttention((prev) => {
          if (!prev.has(activeSessionId)) return prev;
          const next = new Set(prev);
          next.delete(activeSessionId);
          return next;
        });
      }
    };

    // Clear immediately if already visible
    clear();

    // Also clear when tab becomes visible
    document.addEventListener("visibilitychange", clear);
    return () => document.removeEventListener("visibilitychange", clear);
  }, [activeSessionId]);

  // Detect transitions, fire notifications, mark attention
  useEffect(() => {
    const prev = prevRef.current;
    const next = new Map<number, Snapshot>();
    const canNotify =
      "Notification" in window &&
      Notification.permission === "granted" &&
      document.hidden;

    for (const [sid, s] of sessions) {
      next.set(sid, { alive: s.alive, isProcessing: s.isProcessing });
      const p = prev.get(sid);
      if (!p) continue;

      const title = s.title || `Session ${sid}`;

      // Session completed (alive → not alive)
      if (p.alive && !s.alive) {
        if (canNotify) {
          new Notification(title, {
            body: lastMessageText(s),
            tag: `cydo-${sid}`,
          });
        }
        setAttention((a) => new Set(a).add(sid));
        continue;
      }

      // Awaiting user input (was processing → now idle, still alive)
      if (p.isProcessing && !s.isProcessing && s.alive) {
        if (canNotify) {
          new Notification(title, {
            body: lastMessageText(s),
            tag: `cydo-${sid}`,
          });
        }
        setAttention((a) => new Set(a).add(sid));
      }
    }

    prevRef.current = next;
  }, [sessions]);

  return attention;
}
