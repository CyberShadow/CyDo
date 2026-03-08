// Browser notification support and sidebar attention tracking.
//
// The SharedWorker (via Blob URL) maintains its own WebSocket connection and is
// the sole owner of browser Notification objects.  Because SharedWorkers are NOT
// frozen when the tab is backgrounded, notifications fire reliably even when the
// browser is on another workspace.  Dismissal also happens inside the worker
// (same execution context), so Notification.close() works reliably.
//
// The main thread manages the attention set (sidebar badges) and falls back to
// creating Notifications only when SharedWorker is unavailable.
//
// notifyTransition() is called from session state updaters when WebSocket
// messages arrive, handling the attention set synchronously.

import { useEffect, useState } from "preact/hooks";
import type { TaskState as SessionState } from "./types";

// ---------------------------------------------------------------------------
// Imperative notification tracker — for the inline (WebSocket) path
// ---------------------------------------------------------------------------

interface Snapshot {
  alive: boolean;
  isProcessing: boolean;
}

const snapshots = new Map<number, Snapshot>();
const activeNotifications = new Map<number, Notification>();

// Suppresses notifications/attention during initial WebSocket replay.
let replayDone = false;

/** Call when connection opens to reset replay state. */
export function resetReplay() {
  replayDone = false;
}

/** Call after replay messages have settled to enable notifications. */
export function markReplayDone() {
  replayDone = true;
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

// Listeners notified when the attention set changes (for React state sync).
type AttentionListener = (sids: Set<number>) => void;
const attentionListeners = new Set<AttentionListener>();
let attentionSet = new Set<number>();

// Currently viewed task — suppresses attention when tab is visible.
let activeVisibleTid: number | null = null;

// Callback to send dismiss_attention to the backend (set by the hook).
let sendDismiss: ((tid: number) => void) | null = null;

function addAttention(tid: number, source = "inline") {
  if (!replayDone) return;
  if (tid === activeVisibleTid && document.hasFocus()) {
    if (source !== "worker") sendDismiss?.(tid);
    return;
  }
  if (attentionSet.has(tid)) return;
  attentionSet = new Set(attentionSet);
  attentionSet.add(tid);
  for (const fn of attentionListeners) fn(attentionSet);
}

export function removeAttention(tid: number, broadcast = true) {
  const inSet = attentionSet.has(tid);
  const hasNotification = activeNotifications.has(tid);
  if (!inSet && !hasNotification) return;
  if (inSet) {
    attentionSet = new Set(attentionSet);
    attentionSet.delete(tid);
    for (const fn of attentionListeners) fn(attentionSet);
  }
  activeNotifications.get(tid)?.close();
  activeNotifications.delete(tid);
  if (broadcast) sendDismiss?.(tid);
}

/**
 * Called from session state updaters to detect transitions and fire
 * notifications synchronously, independent of React rendering.
 */
export function notifyTransition(
  tid: number,
  prev: SessionState,
  next: SessionState,
) {
  const p = snapshots.get(tid);
  snapshots.set(tid, { alive: next.alive, isProcessing: next.isProcessing });
  if (!p || !replayDone) return;

  const finished = p.alive && !next.alive;
  const awaiting = p.isProcessing && !next.isProcessing && next.alive;
  if (!finished && !awaiting) return;

  addAttention(tid);

  // Send the notification body to the worker so it can show message content
  // instead of generic text.  When tabs are frozen this won't arrive, and
  // the worker falls back to "Task finished" / "Awaiting input".
  if (worker) {
    const body = lastMessageText(next);
    if (body) {
      worker.port.postMessage({ type: "notify-body", tid, body });
    }
  }

  // Create browser notification only as fallback when SharedWorker is
  // unavailable.  Normally the worker owns all Notification objects.
  if (
    !worker &&
    !document.hasFocus() &&
    "Notification" in window &&
    Notification.permission === "granted"
  ) {
    const title = next.title || `Task ${tid}`;
    const body = lastMessageText(next);
    const n = new Notification(title, { body, tag: `cydo-${tid}` });
    activeNotifications.set(tid, n);
  }
}

/** Update snapshot without firing notifications (e.g. initial load). */
export function initSnapshot(tid: number, state: SessionState) {
  snapshots.set(tid, { alive: state.alive, isProcessing: state.isProcessing });
}

// ---------------------------------------------------------------------------
// SharedWorker via Blob URL — own WebSocket, independent of tab freeze
// ---------------------------------------------------------------------------

function makeWorkerCode(wsUrl: string) {
  return `
var WS_URL = "${wsUrl}";
var snapshots = new Map();
var activeNotifications = new Map();
var ports = [];
var replayDone = false;
var replayTimer = null;

var portFocus = [];

self.onconnect = function(e) {
  var port = e.ports[0];
  var idx = ports.length;
  ports.push(port);
  portFocus.push(false);
  port.onmessage = function(msg) {
    if (msg.data && msg.data.type === "tab-state") {
      portFocus[idx] = msg.data.hasFocus;
    } else if (msg.data && msg.data.type === "notify-body") {
      var s = snapshots.get(msg.data.tid);
      if (s) s.body = msg.data.body;
    }
  };
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
  if (raw.type === "tasks_list") {
    var entries = raw.tasks || [];
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      var prev = snapshots.get(entry.tid);
      if (!prev) {
        snapshots.set(entry.tid, { alive: entry.alive, isProcessing: false, title: entry.title || "" });
      } else {
        var old = { alive: prev.alive, isProcessing: prev.isProcessing };
        prev.alive = entry.alive;
        if (entry.title) prev.title = entry.title;
        if (replayDone) checkTransition(entry.tid, old, prev);
      }
    }
    return;
  }

  if (raw.type === "dismiss_attention") {
    var n = activeNotifications.get(raw.tid);
    if (n) {
      try { n.close(); } catch(e) {}
      activeNotifications.delete(raw.tid);
    }
    for (var k = 0; k < ports.length; k++) {
      ports[k].postMessage({ type: "dismiss_attention", tid: raw.tid });
    }
    return;
  }

  if (raw.type === "title_update") {
    var snap = snapshots.get(raw.tid);
    if (snap) snap.title = raw.title;
    return;
  }

  if (typeof raw.tid === "number" && raw.event) {
    var tid = raw.tid;
    var event = raw.event;
    var snap = snapshots.get(tid);
    if (!snap) {
      snap = { alive: true, isProcessing: false, title: "" };
      snapshots.set(tid, snap);
    }
    var prev = { alive: snap.alive, isProcessing: snap.isProcessing };

    if (event.type === "system" && event.subtype === "init") {
      snap.alive = true;
      snap.isProcessing = true;
    } else if (event.type === "assistant" && event.message && event.message.content) {
      // Extract last text block from assistant messages so we have a body
      // for notifications without relying on the (possibly frozen) main thread.
      var blocks = event.message.content;
      for (var bi = blocks.length - 1; bi >= 0; bi--) {
        if (blocks[bi].type === "text" && blocks[bi].text) {
          var t = blocks[bi].text.trim();
          if (t) { snap.lastText = t.length > 200 ? t.slice(0, 200) + "\u2026" : t; break; }
        }
      }
    } else if (event.type === "result") {
      snap.isProcessing = false;
    } else if (event.type === "exit") {
      snap.alive = false;
      snap.isProcessing = false;
    }

    if (replayDone) checkTransition(tid, prev, snap);
  }
}

function anyTabFocused() {
  for (var i = 0; i < portFocus.length; i++) {
    if (portFocus[i]) return true;
  }
  return false;
}

function checkTransition(sid, prev, next) {
  var finished = prev.alive && !next.alive;
  var awaiting = prev.isProcessing && !next.isProcessing && next.alive;
  if (!finished && !awaiting) return;

  // Clear stale body from a previous transition so we don't reuse it.
  next.body = undefined;

  for (var j = 0; j < ports.length; j++) {
    ports[j].postMessage({ type: "attention", tid: sid });
  }

  if (!anyTabFocused() && typeof Notification !== "undefined") {
    var snap = next;
    var f = finished;
    var title = snap.title || ("Task " + sid);
    var body = snap.body || snap.lastText || (f ? "Task finished" : "Awaiting input");
    var n = new Notification(title, { body: body, tag: "cydo-" + sid });
    activeNotifications.set(sid, n);
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
        addAttention(e.data.tid, "worker");
      } else if (e.data?.type === "dismiss_attention") {
        removeAttention(e.data.tid, false);
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

export function useNotifications(
  activeTaskId: number | null,
  onDismiss?: (tid: number) => void,
) {
  const [attention, setAttention] = useState<Set<number>>(attentionSet);

  // Wire up the dismiss callback so removeAttention can notify the backend
  useEffect(() => {
    sendDismiss = onDismiss ?? null;
    return () => {
      sendDismiss = null;
    };
  }, [onDismiss]);

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

  // Start the SharedWorker and report focus state
  useEffect(() => {
    startWorker();
    const sendFocus = () => {
      worker?.port.postMessage({
        type: "tab-state",
        hasFocus: document.hasFocus(),
      });
    };
    sendFocus();
    window.addEventListener("focus", sendFocus);
    window.addEventListener("blur", sendFocus);
    document.addEventListener("visibilitychange", sendFocus);
    return () => {
      window.removeEventListener("focus", sendFocus);
      window.removeEventListener("blur", sendFocus);
      document.removeEventListener("visibilitychange", sendFocus);
    };
  }, []);

  // Track active session and clear attention when it's focused
  useEffect(() => {
    activeVisibleTid = activeTaskId;
    if (activeTaskId === null) return;

    const clear = () => {
      if (document.hasFocus()) removeAttention(activeTaskId);
    };

    clear();
    window.addEventListener("focus", clear);
    return () => {
      window.removeEventListener("focus", clear);
      activeVisibleTid = null;
    };
  }, [activeTaskId]);

  return attention;
}
