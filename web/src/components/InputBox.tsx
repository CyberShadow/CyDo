import { h, RefObject } from "preact";
import { useState, useRef, useEffect, useMemo } from "preact/hooks";

const drafts = new Map<number, string>();

interface Props {
  onSend: (text: string) => void;
  onInterrupt: () => void;
  isProcessing: boolean;
  disabled: boolean;
  sessionId: number;
  inputDraft?: string;
  onInputDraftConsumed?: () => void;
  serverDraft?: string;
  onSaveDraft?: (text: string) => void;
  inputRef?: RefObject<HTMLTextAreaElement>;
  insertTextRef?: RefObject<((text: string) => void) | null>;
  onEscape?: () => void;
  suggestions?: string[];
}

function debounce<T extends (...args: any[]) => void>(
  fn: T,
  ms: number,
): T & { cancel: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const debounced = (...args: Parameters<T>) => {
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn(...args);
    }, ms);
  };
  debounced.cancel = () => {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
  };
  return debounced as T & { cancel: () => void };
}

export function InputBox({
  onSend,
  onInterrupt,
  isProcessing,
  disabled,
  sessionId,
  inputDraft,
  onInputDraftConsumed,
  serverDraft,
  onSaveDraft,
  inputRef,
  insertTextRef,
  onEscape,
  suggestions,
}: Props) {
  const [text, setText] = useState(() => {
    const memDraft = drafts.get(sessionId);
    if (memDraft !== undefined) return memDraft;
    return serverDraft ?? "";
  });
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const textRef = useRef(text);
  textRef.current = text;

  const saveDraftDebounced = useMemo(
    () => debounce((t: string) => onSaveDraft?.(t), 500),
    [onSaveDraft],
  );

  useEffect(() => {
    // On sessionId change: use in-memory draft if available, else server draft
    const memDraft = drafts.get(sessionId);
    setText(memDraft !== undefined ? memDraft : (serverDraft ?? ""));
    return () => {
      drafts.set(sessionId, textRef.current);
      saveDraftDebounced.cancel();
    };
  }, [sessionId]);

  useEffect(() => {
    if (!insertTextRef) return;
    insertTextRef.current = (quoted: string) => {
      setText((prev) => (prev ? `${prev}\n\n${quoted}` : quoted));
      textareaRef.current?.focus();
    };
    return () => {
      insertTextRef.current = null;
    };
  }, [insertTextRef]);

  // Pre-fill with unsaved user messages recovered after session reload
  useEffect(() => {
    if (!inputDraft) return;
    setText((prev) => (prev ? inputDraft + "\n\n" + prev : inputDraft));
    onInputDraftConsumed?.();
  }, [inputDraft]);

  const handleChange = (newText: string) => {
    setText(newText);
    drafts.set(sessionId, newText);
    saveDraftDebounced(newText);
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    } else if (e.key === "Escape" && onEscape) {
      e.preventDefault();
      onEscape();
    }
  };

  const send = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setText("");
    drafts.set(sessionId, "");
    saveDraftDebounced.cancel();
    onSaveDraft?.("");
    textareaRef.current?.focus();
  };

  return (
    <div class="input-box">
      {!isProcessing &&
        !text.trim() &&
        suggestions &&
        suggestions.length > 0 && (
          <div class="suggestions">
            {suggestions.map((s) => (
              <button
                key={s}
                class="btn btn-suggestion"
                draggable
                onDragStart={(e) => {
                  e.dataTransfer!.setData("text/plain", s);
                  e.dataTransfer!.effectAllowed = "copy";
                }}
                onClick={(e) => {
                  if (e.shiftKey) {
                    handleChange(s);
                    textareaRef.current?.focus();
                  } else {
                    onSend(s);
                  }
                }}
                title="Click to send, drag and drop to edit"
              >
                {s}
              </button>
            ))}
          </div>
        )}
      <textarea
        ref={textareaRef}
        class="input-textarea"
        value={text}
        onInput={(e) => {
          handleChange((e.target as HTMLTextAreaElement).value);
        }}
        onBlur={() => {
          onSaveDraft?.(textRef.current);
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
