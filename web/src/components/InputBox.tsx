import { h, RefObject } from "preact";
import { useState, useRef, useEffect } from "preact/hooks";

const drafts = new Map<number, string>();

interface Props {
  onSend: (text: string) => void;
  onInterrupt: () => void;
  isProcessing: boolean;
  disabled: boolean;
  sessionId: number;
  preReloadDrafts?: string[];
  inputRef?: RefObject<HTMLTextAreaElement>;
}

export function InputBox({
  onSend,
  onInterrupt,
  isProcessing,
  disabled,
  sessionId,
  preReloadDrafts,
  inputRef,
}: Props) {
  const [text, setText] = useState(() => drafts.get(sessionId) ?? "");
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const textRef = useRef(text);
  textRef.current = text;

  useEffect(() => {
    setText(drafts.get(sessionId) ?? "");
    return () => {
      drafts.set(sessionId, textRef.current);
    };
  }, [sessionId]);

  // Pre-fill with unsaved user messages recovered after session reload
  useEffect(() => {
    if (preReloadDrafts && preReloadDrafts.length > 0) {
      const recovered = preReloadDrafts.join("\n\n");
      setText((prev) => (prev ? recovered + "\n\n" + prev : recovered));
    }
  }, [preReloadDrafts]);

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  };

  const send = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setText("");
    textareaRef.current?.focus();
  };

  return (
    <div class="input-box">
      <textarea
        ref={textareaRef}
        class="input-textarea"
        value={text}
        onInput={(e) => {
          setText((e.target as HTMLTextAreaElement).value);
        }}
        onKeyDown={handleKeyDown}
        placeholder={disabled ? "Connecting..." : "Type a message..."}
        disabled={disabled}
        rows={1}
      />
      {isProcessing && (
        <button class="btn btn-stop" onClick={onInterrupt}>
          Stop
        </button>
      )}
      <button
        class="btn btn-send"
        onClick={send}
        disabled={disabled || !text.trim()}
      >
        Send
      </button>
    </div>
  );
}
