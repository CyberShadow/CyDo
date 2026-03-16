// Browser notification support and sidebar attention tracking.
//
// Attention state is owned by the backend (needsAttention field on tasks).
// The frontend derives the attention set from the tasks map.
//
// A SharedWorker maintains its own WebSocket connection and watches for
// needsAttention transitions in tasks_list to create browser Notifications
// reliably even when all tabs are backgrounded/frozen.

import { useEffect, useMemo, useRef } from "preact/hooks";
import type { TaskState } from "./types";

// ---------------------------------------------------------------------------
// SharedWorker — detects needsAttention transitions for browser Notifications
// ---------------------------------------------------------------------------

function makeWorkerCode(wsUrl: string) {
  return `
var WS_URL = "${wsUrl}";
var state = new Map();
var notifications = new Map();
var ports = [];
var portFocus = [];
var initialized = false;

self.onconnect = function(e) {
  var port = e.ports[0];
  var idx = ports.length;
  ports.push(port);
  portFocus.push(false);
  port.onmessage = function(msg) {
    if (msg.data && msg.data.type === "tab-state") {
      portFocus[idx] = msg.data.hasFocus;
    }
  };
  port.start();
};

function anyTabFocused() {
  for (var i = 0; i < portFocus.length; i++) {
    if (portFocus[i]) return true;
  }
  return false;
}

function connect() {
  var ws = new WebSocket(WS_URL);
  ws.binaryType = "arraybuffer";
  ws.onopen = function() {
    initialized = false;
    state.clear();
    notifications.forEach(function(n) { try { n.close(); } catch(e) {} });
    notifications.clear();
  };
  ws.onclose = function() { setTimeout(connect, 3000); };
  ws.onerror = function() { ws.close(); };
  ws.onmessage = function(ev) {
    try {
      var text = typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data);
      var raw = JSON.parse(text);
      if (raw.type === "tasks_list") handleTasksList(raw.tasks || []);
      else if (raw.type === "task_updated" && raw.task) handleTasksList([raw.task]);
    } catch(e) {}
  };
}

function handleTasksList(entries) {
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    var prev = state.get(e.tid);
    var wasAttention = prev ? prev.needsAttention : false;
    state.set(e.tid, { needsAttention: !!e.needsAttention });

    if (!initialized) continue;

    if (!wasAttention && e.needsAttention) {
      if (!anyTabFocused() && typeof Notification !== "undefined") {
        var title = e.title || ("Task " + e.tid);
        var body = e.notificationBody || "Awaiting input";
        var n = new Notification(title, { body: body, tag: "cydo-" + e.tid });
        notifications.set(e.tid, n);
      }
    } else if (wasAttention && !e.needsAttention) {
      var existing = notifications.get(e.tid);
      if (existing) {
        try { existing.close(); } catch(ex) {}
        notifications.delete(e.tid);
      }
    }
  }
  initialized = true;
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
    worker.onerror = (e) => console.error("[CyDo] SharedWorker error:", e);
    worker.port.start();
  } catch (e) {
    console.error("[CyDo] Failed to create SharedWorker:", e);
    worker = null;
  }
}

// ---------------------------------------------------------------------------
// React hook — permission, attention set derivation, auto-dismiss, worker
// ---------------------------------------------------------------------------

export function useNotifications(
  activeTaskId: string | null,
  tasks: Map<number, TaskState>,
  onDismiss?: (tid: number) => void,
): Set<number> {
  // Derive attention set from tasks map
  const attention = useMemo(() => {
    const set = new Set<number>();
    for (const [tid, t] of tasks) {
      if (t.needsAttention) set.add(tid);
    }
    return set;
  }, [tasks]);

  // Auto-dismiss: when viewing a task with attention and tab is focused
  const onDismissRef = useRef(onDismiss);
  onDismissRef.current = onDismiss;

  useEffect(() => {
    if (activeTaskId === null) return;
    const tid = activeTaskId !== null ? parseInt(activeTaskId, 10) : NaN;
    const t = !isNaN(tid) ? tasks.get(tid) : undefined;
    if (!t?.needsAttention) return;

    const dismiss = () => {
      if (document.hasFocus()) onDismissRef.current?.(tid);
    };
    dismiss(); // dismiss immediately if focused
    window.addEventListener("focus", dismiss);
    return () => window.removeEventListener("focus", dismiss);
  }, [activeTaskId, tasks]);

  // Request Notification permission
  useEffect(() => {
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission();
    }
  }, []);

  // Start SharedWorker and report focus state
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

  return attention;
}
