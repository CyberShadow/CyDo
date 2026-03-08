import type {
  ClaudeMessage,
  ClaudeFileMessage,
  ControlMessage,
} from "./schemas";

export class Connection {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;

  onTaskMessage:
    | ((tid: number, msg: ClaudeMessage, isUnconfirmed?: boolean) => void)
    | null = null;
  onFileMessage: ((tid: number, msg: ClaudeFileMessage) => void) | null = null;
  onControlMessage: ((msg: ControlMessage) => void) | null = null;
  onStatusChange: ((connected: boolean) => void) | null = null;

  connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    this.ws = new WebSocket(`${proto}//${location.host}/ws`);

    this.ws.onopen = () => {
      this.onStatusChange?.(true);
    };

    this.ws.onclose = () => {
      this.onStatusChange?.(false);
      this.scheduleReconnect();
    };

    this.ws.onerror = () => {
      this.ws?.close();
    };

    this.ws.onmessage = (ev) => {
      try {
        const raw = JSON.parse(ev.data);
        if (
          raw.type === "task_created" ||
          raw.type === "tasks_list" ||
          raw.type === "task_reload" ||
          raw.type === "title_update" ||
          raw.type === "task_history_end" ||
          raw.type === "workspaces_list" ||
          raw.type === "forkable_uuids" ||
          raw.type === "error" ||
          raw.type === "dismiss_attention"
        ) {
          this.onControlMessage?.(raw as ControlMessage);
        } else if ("tid" in raw && typeof raw.tid === "number") {
          if ("event" in raw) {
            this.onTaskMessage?.(
              raw.tid,
              raw.event as ClaudeMessage,
              raw.isUnconfirmed === true,
            );
          } else if ("fileEvent" in raw) {
            this.onFileMessage?.(raw.tid, raw.fileEvent as ClaudeFileMessage);
          } else {
            console.warn("Unknown task envelope (no event or fileEvent):", raw);
          }
        } else {
          console.warn("Unknown WebSocket message:", raw);
        }
      } catch (e) {
        console.warn("Failed to parse WebSocket message:", ev.data, e);
      }
    };
  }

  sendMessage(tid: number, content: string) {
    this.ws?.send(JSON.stringify({ type: "message", tid, content }));
  }

  sendInterrupt(tid: number) {
    this.ws?.send(JSON.stringify({ type: "interrupt", tid }));
  }

  resumeTask(tid: number) {
    this.ws?.send(JSON.stringify({ type: "resume", tid }));
  }

  createTask(workspace?: string, projectPath?: string) {
    this.ws?.send(
      JSON.stringify({
        type: "create_task",
        workspace: workspace ?? "",
        project_path: projectPath ?? "",
      }),
    );
  }

  requestHistory(tid: number) {
    this.ws?.send(JSON.stringify({ type: "request_history", tid }));
  }

  forkTask(tid: number, afterUuid: string) {
    this.ws?.send(
      JSON.stringify({ type: "fork_task", tid, after_uuid: afterUuid }),
    );
  }

  dismissAttention(tid: number) {
    this.ws?.send(JSON.stringify({ type: "dismiss_attention", tid }));
  }

  private scheduleReconnect() {
    if (this.reconnectTimer || this.disposed) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 2000);
  }

  disconnect() {
    this.disposed = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
  }
}
