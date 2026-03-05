import type {
  ClaudeMessage,
  ClaudeFileMessage,
  ControlMessage,
} from "./schemas";

export class Connection {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;

  onSessionMessage: ((sid: number, msg: ClaudeMessage) => void) | null = null;
  onFileMessage: ((sid: number, msg: ClaudeFileMessage) => void) | null = null;
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
          raw.type === "session_created" ||
          raw.type === "sessions_list" ||
          raw.type === "session_reload" ||
          raw.type === "title_update" ||
          raw.type === "session_history_end"
        ) {
          this.onControlMessage?.(raw as ControlMessage);
        } else if ("sid" in raw && typeof raw.sid === "number") {
          if ("event" in raw) {
            this.onSessionMessage?.(raw.sid, raw.event as ClaudeMessage);
          } else if ("fileEvent" in raw) {
            this.onFileMessage?.(raw.sid, raw.fileEvent as ClaudeFileMessage);
          } else {
            console.warn(
              "Unknown session envelope (no event or fileEvent):",
              raw,
            );
          }
        } else {
          console.warn("Unknown WebSocket message:", raw);
        }
      } catch (e) {
        console.warn("Failed to parse WebSocket message:", ev.data, e);
      }
    };
  }

  sendMessage(sid: number, content: string) {
    this.ws?.send(JSON.stringify({ type: "message", sid, content }));
  }

  sendInterrupt(sid: number) {
    this.ws?.send(JSON.stringify({ type: "interrupt", sid }));
  }

  resumeSession(sid: number) {
    this.ws?.send(JSON.stringify({ type: "resume", sid }));
  }

  createSession() {
    this.ws?.send(JSON.stringify({ type: "create_session" }));
  }

  requestHistory(sid: number) {
    this.ws?.send(JSON.stringify({ type: "request_history", sid }));
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
