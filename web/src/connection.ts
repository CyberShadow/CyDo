import type { ClaudeMessage } from "./protocol";

export class Connection {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  onMessage: ((msg: ClaudeMessage) => void) | null = null;
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
        const msg = JSON.parse(ev.data) as ClaudeMessage;
        this.onMessage?.(msg);
      } catch {
        // ignore malformed messages
      }
    };
  }

  sendMessage(content: string) {
    this.ws?.send(JSON.stringify({ type: "message", content }));
  }

  sendInterrupt() {
    this.ws?.send(JSON.stringify({ type: "interrupt" }));
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
