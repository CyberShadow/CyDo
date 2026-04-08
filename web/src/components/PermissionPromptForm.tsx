import { useState } from "preact/hooks";

interface Props {
  toolName: string;
  input: Record<string, unknown>;
  onAllow: () => void;
  onDeny: (message?: string) => void;
}

export function PermissionPromptForm({
  toolName,
  input,
  onAllow,
  onDeny,
}: Props) {
  const [showDenyReason, setShowDenyReason] = useState(false);
  const [denyReason, setDenyReason] = useState("");

  return (
    <div class="permission-prompt-form">
      <div class="permission-prompt-header">Permission Request</div>
      <div class="permission-prompt-tool">{toolName}</div>
      <pre class="permission-prompt-input">
        {JSON.stringify(input, null, 2)}
      </pre>
      <div class="permission-prompt-actions">
        <button class="permission-allow-btn" onClick={onAllow}>
          Allow
        </button>
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
      </div>
    </div>
  );
}
