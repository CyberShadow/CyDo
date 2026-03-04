// Browser notification support and sidebar attention tracking.
//
// Two notification paths:
// 1. Inline: notifyTransition() is called from session state updaters when
//    WebSocket messages arrive. Works when the browser dispatches WS events.
// 2. SharedWorker: A SharedWorker (via Blob URL) maintains its own WebSocket
//    connection to the backend. SharedWorkers are NOT frozen when the tab is,
//    so notifications fire even when the browser is on another workspace.

import { useEffect, useState } from "preact/hooks";
import type { SessionState } from "./types";

// ---------------------------------------------------------------------------
// Imperative notification tracker — for the inline (WebSocket) path
// ---------------------------------------------------------------------------

interface Snapshot {
  alive: boolean;
  isProcessing: boolean;
}

const snapshots = new Map<number, Snapshot>();

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

// Listeners notified when the attention set changes (for React state sync).
type AttentionListener = (sids: Set<number>) => void;
const attentionListeners = new Set<AttentionListener>();
let attentionSet = new Set<number>();

function addAttention(sid: number) {
  if (attentionSet.has(sid)) return;
  attentionSet = new Set(attentionSet);
  attentionSet.add(sid);
  for (const fn of attentionListeners) fn(attentionSet);
}

export function removeAttention(sid: number) {
  if (!attentionSet.has(sid)) return;
  attentionSet = new Set(attentionSet);
  attentionSet.delete(sid);
  for (const fn of attentionListeners) fn(attentionSet);
}

/**
 * Called from session state updaters to detect transitions and fire
 * notifications synchronously, independent of React rendering.
 */
export function notifyTransition(
  sid: number,
  prev: SessionState,
  next: SessionState,
) {
  const p = snapshots.get(sid);
  snapshots.set(sid, { alive: next.alive, isProcessing: next.isProcessing });
  if (!p) return;

  const finished = p.alive && !next.alive;
  const awaiting = p.isProcessing && !next.isProcessing && next.alive;
  if (!finished && !awaiting) return;

  addAttention(sid);

  if (
    !document.hasFocus() &&
    "Notification" in window &&
    Notification.permission === "granted"
  ) {
    const title = next.title || `Session ${sid}`;
    const body = lastMessageText(next);
    new Notification(title, { body, tag: `cydo-${sid}` });
  }
}

/** Update snapshot without firing notifications (e.g. initial load). */
export function initSnapshot(sid: number, state: SessionState) {
  snapshots.set(sid, { alive: state.alive, isProcessing: state.isProcessing });
}

// ---------------------------------------------------------------------------
// SharedWorker via Blob URL — own WebSocket, independent of tab freeze
// ---------------------------------------------------------------------------

function makeWorkerCode(wsUrl: string) {
  return `
var WS_URL = "${wsUrl}";
var snapshots = new Map();
var ports = [];
var replayDone = false;
var replayTimer = null;

self.onconnect = function(e) {
  var port = e.ports[0];
  ports.push(port);
  port.start();
};

function connect() {
  var ws = new WebSocket(WS_URL);

  ws.onopen = function() {
    replayDone = false;
    snapshots.clear();
  };

  ws.onclose = function() {
    if (replayTimer) { clearTimeout(replayTimer); replayTimer = null; }
    setTimeout(connect, 3000);
  };

  ws.onerror = function() { ws.close(); };

  ws.onmessage = function(ev) {
    try {
      var raw = JSON.parse(ev.data);
      handleMessage(raw);
    } catch (e) {}
    if (!replayDone) {
      if (replayTimer) clearTimeout(replayTimer);
      replayTimer = setTimeout(function() { replayDone = true; replayTimer = null; }, 1000);
    }
  };
}

function handleMessage(raw) {
  if (raw.type === "sessions_list") {
    var entries = raw.sessions || [];
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      var prev = snapshots.get(entry.sid);
      if (!prev) {
        snapshots.set(entry.sid, { alive: entry.alive, isProcessing: false, title: entry.title || "" });
      } else {
        var old = { alive: prev.alive, isProcessing: prev.isProcessing };
        prev.alive = entry.alive;
        if (entry.title) prev.title = entry.title;
        if (replayDone) checkTransition(entry.sid, old, prev);
      }
    }
    return;
  }

  if (raw.type === "title_update") {
    var snap = snapshots.get(raw.sid);
    if (snap) snap.title = raw.title;
    return;
  }

  if (typeof raw.sid === "number" && raw.event) {
    var sid = raw.sid;
    var event = raw.event;
    var snap = snapshots.get(sid);
    if (!snap) {
      snap = { alive: true, isProcessing: false, title: "" };
      snapshots.set(sid, snap);
    }
    var prev = { alive: snap.alive, isProcessing: snap.isProcessing };

    if (event.type === "system" && event.subtype === "init") {
      snap.alive = true;
      snap.isProcessing = true;
    } else if (event.type === "result") {
      snap.isProcessing = false;
    } else if (event.type === "exit") {
      snap.alive = false;
      snap.isProcessing = false;
    }

    if (replayDone) checkTransition(sid, prev, snap);
  }
}

function checkTransition(sid, prev, next) {
  var finished = prev.alive && !next.alive;
  var awaiting = prev.isProcessing && !next.isProcessing && next.alive;
  if (!finished && !awaiting) return;

  var title = next.title || ("Session " + sid);
  var body = finished ? "Session finished" : "Awaiting input";
  try { new Notification(title, { body: body, tag: "cydo-" + sid }); } catch (e) {}

  for (var j = 0; j < ports.length; j++) {
    ports[j].postMessage({ type: "attention", sid: sid });
  }
}

connect();
`;
}

let worker: SharedWorker | null = null;

function startWorker() {
  if (worker) return;
  try {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const wsUrl = `${proto}//${location.host}/ws`;
    const blob = new Blob([makeWorkerCode(wsUrl)], {
      type: "application/javascript",
    });
    const url = URL.createObjectURL(blob);
    worker = new SharedWorker(url, { name: "cydo-notifications" });
    worker.onerror = (e) => {
      console.error("[CyDo] SharedWorker error:", e);
    };
    worker.port.onmessage = (e) => {
      if (e.data?.type === "attention") {
        addAttention(e.data.sid);
      }
    };
    worker.port.start();
  } catch (e) {
    console.error("[CyDo] Failed to create SharedWorker:", e);
    worker = null;
  }
}

// ---------------------------------------------------------------------------
// React hook — permission request, attention set, worker lifecycle
// ---------------------------------------------------------------------------

export function useNotifications(activeSessionId: number | null) {
  const [attention, setAttention] = useState<Set<number>>(attentionSet);

  // Subscribe to imperative attention changes
  useEffect(() => {
    const listener: AttentionListener = (s) => setAttention(s);
    attentionListeners.add(listener);
    return () => {
      attentionListeners.delete(listener);
    };
  }, []);

  // Request permission once on mount
  useEffect(() => {
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission();
    }
  }, []);

  // Start the SharedWorker
  useEffect(() => {
    startWorker();
  }, []);

  // Clear attention for the active session when tab is visible
  useEffect(() => {
    if (activeSessionId === null) return;

    const clear = () => {
      if (!document.hidden) removeAttention(activeSessionId);
    };

    clear();
    document.addEventListener("visibilitychange", clear);
    return () => document.removeEventListener("visibilitychange", clear);
  }, [activeSessionId]);

  return attention;
}
