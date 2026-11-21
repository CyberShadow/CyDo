import { useEffect, useState } from "preact/hooks";

interface Props {
  toolName: string;
  input: Record<string, unknown>;
  /** Why the agent's own safety checks flag the call, if they do. */
  reason?: string;
  /** When CyDo denies the call unanswered (Unix ms); absent: never. */
  expiresAt?: number;
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
  onAllow,
  onDeny,
}: Props) {
  const [showDenyReason, setShowDenyReason] = useState(false);
  const [denyReason, setDenyReason] = useState("");

  return (
    <div class="permission-prompt-form">
      <div class="permission-prompt-header">
        Permission Request
        {expiresAt !== undefined && (
          <PermissionPromptTimeout expiresAt={expiresAt} />
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
              class="permission-deny-reason"
              placeholder="Reason (optional)"
              value={denyReason}
              onInput={(e) => {
                setDenyReason((e.target as HTMLTextAreaElement).value);
              }}
              autoFocus
            />
            <button
              class="permission-deny-btn"
              onClick={() => {
                onDeny(denyReason || undefined);
              }}
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
          >
            Deny
          </button>
        )}
        <button class="permission-allow-btn" onClick={onAllow}>
          Allow
        </button>
      </div>
    </div>
  );
}
