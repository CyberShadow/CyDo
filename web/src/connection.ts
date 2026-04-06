import type { AgnosticEvent, ControlMessage, ContentBlock } from "./protocol";

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
        const data = ev.data as string | ArrayBuffer;
        const text =
          typeof data === "string" ? data : new TextDecoder().decode(data);
        const raw = JSON.parse(text) as Record<string, unknown>;
        if (
          raw.type === "task_created" ||
          raw.type === "tasks_list" ||
          raw.type === "task_updated" ||
          raw.type === "task_reload" ||
          raw.type === "title_update" ||
          raw.type === "task_history_end" ||
          raw.type === "workspaces_list" ||
          raw.type === "task_types_list" ||
          raw.type === "agent_types_list" ||
          raw.type === "forkable_uuids" ||
          raw.type === "error" ||
          raw.type === "undo_preview" ||
          raw.type === "undo_result" ||
          raw.type === "suggestions_update" ||
          raw.type === "ask_user_question" ||
          raw.type === "draft_updated" ||
          raw.type === "server_status" ||
          raw.type === "task_deleted"
        ) {
          this.onControlMessage?.(raw as unknown as ControlMessage);
        } else if ("tid" in raw && typeof raw.tid === "number") {
          if ("unconfirmedUserEvent" in raw) {
            this.onUnconfirmedUserMessage?.(
              raw.tid,
              raw.unconfirmedUserEvent as AgnosticEvent,
            );
          } else if ("event" in raw) {
            const event = raw.event as AgnosticEvent;
            if (typeof raw.seq === "number") {
              (event as Record<string, unknown>)._seq = raw.seq;
            }
            this.onTaskMessage?.(raw.tid, event);
          } else {
            console.warn("Unknown task envelope:", raw);
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

  sendMessage(tid: number, content: ContentBlock[]) {
    this.send(JSON.stringify({ type: "message", tid, content }));
  }

  setTaskType(tid: number, taskType: string) {
    this.send(
      JSON.stringify({ type: "set_task_type", tid, task_type: taskType }),
    );
  }

  setEntryPoint(tid: number, entryPoint: string) {
    this.send(
      JSON.stringify({ type: "set_entry_point", tid, entry_point: entryPoint }),
    );
  }

  setAgentType(tid: number, agentType: string) {
    this.send(
      JSON.stringify({ type: "set_agent_type", tid, agent_type: agentType }),
    );
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

  promoteTask(tid: number) {
    this.send(JSON.stringify({ type: "promote_task", tid }));
  }

  createTask(
    workspace?: string,
    projectPath?: string,
    entryPoint?: string,
    content?: ContentBlock[],
    agentType?: string,
    correlationId?: string,
  ) {
    this.send(
      JSON.stringify({
        type: "create_task",
        workspace: workspace ?? "",
        project_path: projectPath ?? "",
        entry_point: entryPoint ?? "",
        content: content ?? [],
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

  deleteTask(tid: number) {
    this.send(JSON.stringify({ type: "delete_task", tid }));
  }

  sendAskUserResponse(tid: number, content: string) {
    this.send(JSON.stringify({ type: "ask_user_response", tid, content }));
  }

  editMessage(tid: number, uuid: string, content: string) {
    this.send(
      JSON.stringify({ type: "edit_message", tid, after_uuid: uuid, content }),
    );
  }

  refreshWorkspaces() {
    this.send(JSON.stringify({ type: "refresh_workspaces" }));
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
