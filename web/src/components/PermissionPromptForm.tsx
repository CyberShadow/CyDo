import type { RefObject } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";

interface Props {
  toolName: string;
  input: Record<string, unknown>;
  /** Why the agent's own safety checks flag the call, if they do. */
  reason?: string;
  /** When CyDo denies the call unanswered (Unix ms); absent: never. */
  expiresAt?: number;
  /** Answered: awaiting the agent taking the answer. */
  sending?: boolean;
  insertTextRef?: RefObject<((text: string) => void) | null>;
  onAllow: () => void;
  onDeny: (message?: string) => void;
}

/** "m:ss" until `expiresAt`, never negative. */
export function formatTimeLeft(expiresAt: number, nowMs: number): string {
  const seconds = Math.max(0, Math.ceil((expiresAt - nowMs) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** A countdown to when the prompt is denied unanswered. */
function PermissionPromptTimeout({ expiresAt }: { expiresAt: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => {
      setNow(Date.now());
    }, 1000);
    return () => {
      clearInterval(timer);
    };
  }, []);
  return (
    <span class="permission-prompt-timeout">
      Denied automatically in {formatTimeLeft(expiresAt, now)}
    </span>
  );
}

export function PermissionPromptForm({
  toolName,
  input,
  reason,
  expiresAt,
  sending,
  insertTextRef,
  onAllow,
  onDeny,
}: Props) {
  const [showDenyReason, setShowDenyReason] = useState(false);
  const [denyReason, setDenyReason] = useState("");

  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useLayoutEffect(() => {
    if (!insertTextRef || !showDenyReason || sending) return;
    insertTextRef.current = (quoted) => {
      const textarea = textareaRef.current!;
      const previous = textarea.value;
      const value = previous ? `${previous.trimEnd()}\n\n${quoted}` : quoted;
      textarea.value = value;
      setDenyReason(value);
      textarea.focus();
      textarea.setSelectionRange(value.length, value.length);
      textarea.scrollTop = textarea.scrollHeight;
    };
    return () => {
      insertTextRef.current = null;
    };
  }, [insertTextRef, showDenyReason, sending]);

  return (
    <div class={`permission-prompt-form${sending ? " sending" : ""}`}>
      <div class="permission-prompt-header">
        Permission Request
        {sending ? (
          <span class="permission-prompt-sending">
            <span class="permission-prompt-spinner" />
            Sending…
          </span>
        ) : (
          expiresAt !== undefined && (
            <PermissionPromptTimeout expiresAt={expiresAt} />
          )
        )}
      </div>
      <div class="permission-prompt-tool">{toolName}</div>
      {reason && <div class="permission-prompt-reason">{reason}</div>}
      <pre class="permission-prompt-input">
        {JSON.stringify(input, null, 2)}
      </pre>
      <div class="permission-prompt-actions">
        {showDenyReason ? (
          <>
            <textarea
              ref={textareaRef}
              class="text-input permission-deny-reason"
              placeholder="Reason (optional)"
              value={denyReason}
              onInput={(e) => {
                setDenyReason((e.target as HTMLTextAreaElement).value);
              }}
              autoFocus
              disabled={sending}
            />
            <button
              class="permission-deny-btn"
              onClick={() => {
                onDeny(denyReason || undefined);
              }}
              disabled={sending}
            >
              Deny
            </button>
          </>
        ) : (
          <button
            class="permission-deny-btn"
            onClick={() => {
              setShowDenyReason(true);
            }}
            disabled={sending}
          >
            Deny
          </button>
        )}
        <button
          class="permission-allow-btn"
          onClick={onAllow}
          disabled={sending}
        >
          Allow
        </button>
      </div>
    </div>
  );
}
