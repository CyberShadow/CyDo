import type { ComponentChildren, Ref } from "preact";
import editIcon from "../icons/edit.svg?raw";
import type { SessionInfo } from "../types";
import { useCopyFeedback } from "./CopyButton";

export function TaskId({ tid }: { tid: number }) {
  const { copied, copyFailed, onClick } = useCopyFeedback(String(tid));
  return (
    <button
      type="button"
      class="task-bar-id"
      onClick={onClick}
      title={copyFailed ? "Copy failed" : copied ? "Copied!" : "Copy task ID"}
    >
      <span>#{tid}</span>
      {copied && <span>✓</span>}
    </button>
  );
}

interface Props {
  tid: number;
  panelRef: Ref<HTMLElement>;
  title: string;
  /** The unsaved title while the title is being edited, null otherwise. */
  titleDraft: string | null;
  onTitleDraftChange: (draft: string | null) => void;
  titleInputRef: Ref<HTMLInputElement>;
  onSetTitle?: (title: string) => void;
  agentName?: string;
  agentDisplayName?: string;
  taskType?: string;
  entryPoint?: string;
  sessionInfo?: SessionInfo | null;
  cost?: number;
  createdAt?: number;
  lastActive?: number;
  mobileAction: ComponentChildren;
  onClose: () => void;
}

export function TaskPanel({
  tid,
  panelRef,
  title,
  titleDraft,
  onTitleDraftChange,
  titleInputRef,
  onSetTitle,
  agentName,
  agentDisplayName,
  taskType,
  entryPoint,
  sessionInfo,
  cost,
  createdAt,
  lastActive,
  mobileAction,
  onClose,
}: Props) {
  return (
    <section ref={panelRef} class="task-panel" aria-label="Task details">
      <header>
        Task <TaskId tid={tid} />
        <button type="button" onClick={onClose} aria-label="Close task details">
          ×
        </button>
      </header>
      {onSetTitle &&
        (titleDraft === null ? (
          <div class="task-panel-title">
            <span class="detail-label">Title</span>
            <span>{title}</span>
            <button
              type="button"
              class="msg-action-btn"
              onClick={() => {
                onTitleDraftChange(title);
              }}
              aria-label="Edit title"
              title="Edit title"
            >
              <span
                class="action-icon"
                dangerouslySetInnerHTML={{ __html: editIcon }}
              />
            </button>
          </div>
        ) : (
          <form
            class="task-panel-title"
            onSubmit={(event) => {
              event.preventDefault();
              const trimmed = titleDraft.trim();
              // A changed title stays in the editor until the server
              // accepts it, so a rejected edit can be corrected.
              if (trimmed === title) onTitleDraftChange(null);
              else onSetTitle(trimmed);
            }}
          >
            <label>
              <span class="detail-label">Title</span>
              <input
                ref={titleInputRef}
                class="text-input"
                type="text"
                value={titleDraft}
                onInput={(event) => {
                  onTitleDraftChange(event.currentTarget.value);
                }}
              />
            </label>
            <button type="submit" class="btn">
              Save
            </button>
            <button
              type="button"
              class="btn"
              onClick={() => {
                onTitleDraftChange(null);
              }}
            >
              Cancel
            </button>
          </form>
        ))}
      <dl class="task-panel-info">
        {agentName && (
          <div>
            <dt>Agent</dt>
            <dd>
              {agentName}
              {agentDisplayName && ` (${agentDisplayName})`}
            </dd>
          </div>
        )}
        {taskType && (
          <div>
            <dt>Type</dt>
            <dd>{taskType}</dd>
          </div>
        )}
        {entryPoint && (
          <div>
            <dt>Entry point</dt>
            <dd>{entryPoint}</dd>
          </div>
        )}
        {sessionInfo?.model && (
          <div>
            <dt>Model</dt>
            <dd>{sessionInfo.model}</dd>
          </div>
        )}
        {sessionInfo?.permission_mode && (
          <div>
            <dt>Permissions</dt>
            <dd>{sessionInfo.permission_mode}</dd>
          </div>
        )}
        {cost !== undefined && (
          <div>
            <dt>Cost</dt>
            <dd>${cost.toFixed(4)}</dd>
          </div>
        )}
        {createdAt !== undefined && (
          <div>
            <dt>Created</dt>
            <dd>{new Date(createdAt).toLocaleString()}</dd>
          </div>
        )}
        {lastActive !== undefined && (
          <div>
            <dt>Last active</dt>
            <dd>{new Date(lastActive).toLocaleString()}</dd>
          </div>
        )}
      </dl>
      <div class="task-panel-mobile-action">{mobileAction}</div>
      {sessionInfo && (
        <details>
          <summary>Session</summary>
          <div class="task-panel-details">
            {sessionInfo.agent && (
              <div class="task-panel-detail-row">
                <span class="detail-label">Agent:</span> {sessionInfo.agent}
              </div>
            )}
            <div class="task-panel-detail-row">
              <span class="detail-label">Session:</span> {sessionInfo.sessionId}
            </div>
            <div class="task-panel-detail-row">
              <span class="detail-label">Version:</span> {sessionInfo.version}
            </div>
            <div class="task-panel-detail-row">
              <span class="detail-label">Directory:</span> {sessionInfo.cwd}
            </div>
            <div class="task-panel-detail-row">
              <span class="detail-label">Permissions:</span>{" "}
              {sessionInfo.permission_mode}
            </div>
            {sessionInfo.api_key_source && (
              <div class="task-panel-detail-row">
                <span class="detail-label">API Key:</span>{" "}
                {sessionInfo.api_key_source}
              </div>
            )}
            {sessionInfo.fast_mode_state &&
              sessionInfo.fast_mode_state !== "off" && (
                <div class="task-panel-detail-row">
                  <span class="detail-label">Fast mode:</span>{" "}
                  {sessionInfo.fast_mode_state}
                </div>
              )}
            {sessionInfo.tools.length > 0 && (
              <div class="task-panel-detail-row">
                <span class="detail-label">
                  Tools ({sessionInfo.tools.length}):
                </span>
                <span class="detail-tools">{sessionInfo.tools.join(", ")}</span>
              </div>
            )}
            {sessionInfo.skills && sessionInfo.skills.length > 0 && (
              <div class="task-panel-detail-row">
                <span class="detail-label">Skills:</span>{" "}
                {sessionInfo.skills.join(", ")}
              </div>
            )}
            {sessionInfo.mcp_servers && sessionInfo.mcp_servers.length > 0 && (
              <div class="task-panel-detail-row">
                <span class="detail-label">MCP:</span>{" "}
                <pre class="detail-json">
                  {JSON.stringify(sessionInfo.mcp_servers, null, 2)}
                </pre>
              </div>
            )}
            {sessionInfo.agents && sessionInfo.agents.length > 0 && (
              <div class="task-panel-detail-row">
                <span class="detail-label">Agents:</span>{" "}
                <pre class="detail-json">
                  {JSON.stringify(sessionInfo.agents, null, 2)}
                </pre>
              </div>
            )}
            {sessionInfo.plugins && sessionInfo.plugins.length > 0 && (
              <div class="task-panel-detail-row">
                <span class="detail-label">Plugins:</span>{" "}
                <pre class="detail-json">
                  {JSON.stringify(sessionInfo.plugins, null, 2)}
                </pre>
              </div>
            )}
          </div>
        </details>
      )}
    </section>
  );
}
