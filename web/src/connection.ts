import type { ClaudeMessage, ControlMessage } from "./schemas";

export class Connection {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  onSessionMessage: ((sid: number, msg: ClaudeMessage) => void) | null = null;
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
        if (raw.type === "session_created" || raw.type === "sessions_list") {
          this.onControlMessage?.(raw as ControlMessage);
        } else if ("sid" in raw && typeof raw.sid === "number" && "event" in raw) {
          this.onSessionMessage?.(raw.sid, raw.event as ClaudeMessage);
        }
      } catch {
        // ignore malformed messages
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

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 2000);
  }

  disconnect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
  }
}
