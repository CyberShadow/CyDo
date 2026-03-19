import type {
  AgnosticEvent,
  AgnosticFileEvent,
  ControlMessage,
} from "./protocol";

// This module holds stateful class instances that can't be hot-replaced.
// Force a full page reload when it changes.
if (import.meta.hot) import.meta.hot.invalidate();

export class Connection {
  private ws: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;

  onTaskMessage: ((tid: number, msg: AgnosticEvent) => void) | null = null;
  onUnconfirmedUserMessage: ((tid: number, msg: AgnosticEvent) => void) | null =
    null;
  onFileMessage: ((tid: number, msg: AgnosticFileEvent) => void) | null = null;
  onControlMessage: ((msg: ControlMessage) => void) | null = null;
  onStatusChange: ((connected: boolean) => void) | null = null;

  connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    this.ws = new WebSocket(`${proto}//${location.host}/ws`);
    this.ws.binaryType = "arraybuffer";

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
        const text =
          typeof ev.data === "string"
            ? ev.data
            : new TextDecoder().decode(ev.data);
        const raw = JSON.parse(text);
        if (
          raw.type === "task_created" ||
          raw.type === "tasks_list" ||
          raw.type === "task_updated" ||
          raw.type === "task_reload" ||
          raw.type === "title_update" ||
          raw.type === "task_history_end" ||
          raw.type === "workspaces_list" ||
          raw.type === "task_types_list" ||
          raw.type === "forkable_uuids" ||
          raw.type === "error" ||
          raw.type === "undo_preview" ||
          raw.type === "suggestions_update" ||
          raw.type === "ask_user_question" ||
          raw.type === "draft_updated"
        ) {
          this.onControlMessage?.(raw as ControlMessage);
        } else if ("tid" in raw && typeof raw.tid === "number") {
          if ("unconfirmedUserEvent" in raw) {
            this.onUnconfirmedUserMessage?.(
              raw.tid,
              raw.unconfirmedUserEvent as AgnosticEvent,
            );
          } else if ("event" in raw) {
            this.onTaskMessage?.(raw.tid, raw.event as AgnosticEvent);
          } else if ("fileEvent" in raw) {
            this.onFileMessage?.(raw.tid, raw.fileEvent as AgnosticFileEvent);
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

  private send(data: string): boolean {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
      return true;
    }
    return false;
  }

  sendMessage(tid: number, content: string) {
    this.send(JSON.stringify({ type: "message", tid, content }));
  }

  sendInterrupt(tid: number) {
    this.send(JSON.stringify({ type: "interrupt", tid }));
  }

  sendStop(tid: number) {
    this.send(JSON.stringify({ type: "stop", tid }));
  }

  sendCloseStdin(tid: number) {
    this.send(JSON.stringify({ type: "close_stdin", tid }));
  }

  resumeTask(tid: number) {
    this.send(JSON.stringify({ type: "resume", tid }));
  }

  createTask(
    workspace?: string,
    projectPath?: string,
    taskType?: string,
    content?: string,
    agentType?: string,
    correlationId?: string,
  ) {
    this.send(
      JSON.stringify({
        type: "create_task",
        workspace: workspace ?? "",
        project_path: projectPath ?? "",
        task_type: taskType ?? "",
        content: content ?? "",
        agent_type: agentType ?? "",
        correlation_id: correlationId ?? "",
      }),
    );
  }

  requestHistory(tid: number): boolean {
    return this.send(JSON.stringify({ type: "request_history", tid }));
  }

  forkTask(tid: number, afterUuid: string) {
    this.send(
      JSON.stringify({ type: "fork_task", tid, after_uuid: afterUuid }),
    );
  }

  undoTask(
    tid: number,
    afterUuid: string,
    dryRun: boolean,
    revertConversation?: boolean,
    revertFiles?: boolean,
  ) {
    this.send(
      JSON.stringify({
        type: "undo_task",
        tid,
        after_uuid: afterUuid,
        dry_run: dryRun,
        revert_conversation: revertConversation ?? true,
        revert_files: revertFiles ?? true,
      }),
    );
  }

  dismissAttention(tid: number) {
    this.send(JSON.stringify({ type: "dismiss_attention", tid }));
  }

  setArchived(tid: number, archived: boolean) {
    this.send(
      JSON.stringify({ type: "set_archived", tid, content: String(archived) }),
    );
  }

  saveDraft(tid: number, draft: string) {
    this.send(JSON.stringify({ type: "set_draft", tid, content: draft }));
  }

  sendAskUserResponse(tid: number, content: string) {
    this.send(JSON.stringify({ type: "ask_user_response", tid, content }));
  }

  editMessage(tid: number, uuid: string, content: string) {
    this.send(
      JSON.stringify({ type: "edit_message", tid, after_uuid: uuid, content }),
    );
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
