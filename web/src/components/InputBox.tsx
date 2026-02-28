import { h } from "preact";
import { useState, useRef } from "preact/hooks";

interface Props {
  onSend: (text: string) => void;
  onInterrupt: () => void;
  isProcessing: boolean;
  disabled: boolean;
}

export function InputBox({ onSend, onInterrupt, isProcessing, disabled }: Props) {
  const [text, setText] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  };

  const send = () => {
    const trimmed = text.trim();
    if (!trimmed || isProcessing) return;
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
        onInput={(e) => setText((e.target as HTMLTextAreaElement).value)}
        onKeyDown={handleKeyDown}
        placeholder={disabled ? "Connecting..." : "Type a message..."}
        disabled={disabled || isProcessing}
        rows={1}
      />
      {isProcessing ? (
        <button class="btn btn-stop" onClick={onInterrupt}>
          Stop
        </button>
      ) : (
        <button class="btn btn-send" onClick={send} disabled={disabled || !text.trim()}>
          Send
        </button>
      )}
    </div>
  );
}
