import { RefObject } from "preact";
import {
  useState,
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
} from "preact/hooks";
import type { ImageAttachment } from "../useSessionManager";

export const drafts = new Map<number, string>();

const supportsFieldSizing = CSS.supports("field-sizing", "content");

interface Props {
  onSend: (text: string, images?: ImageAttachment[]) => void;
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
  pasteTextRef?: RefObject<((text: string) => void) | null>;
  onEscape?: () => void;
  suggestions?: string[];
  onContentStart?: () => void;
  onContentEnd?: () => void;
}

function debounce<A extends unknown[]>(
  fn: (...args: A) => void,
  ms: number,
): ((...args: A) => void) & { cancel: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const debounced = (...args: A) => {
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
  return debounced;
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
  pasteTextRef,
  onEscape,
  suggestions,
  onContentStart,
  onContentEnd,
}: Props) {
  const [text, setText] = useState(() => {
    const memDraft = drafts.get(sessionId);
    if (memDraft !== undefined) return memDraft;
    return serverDraft ?? "";
  });
  const [images, setImages] = useState<ImageAttachment[]>([]);
  const [isDragging, setIsDragging] = useState(false);
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const textRef = useRef(text);
  textRef.current = text;
  const lastServerDraftRef = useRef<string>(serverDraft ?? "");

  const saveDraftDebounced = useMemo(
    () => debounce((t: string) => onSaveDraft?.(t), 500),
    [onSaveDraft],
  );

  useEffect(() => {
    // On sessionId change: use in-memory draft if available, else server draft
    const memDraft = drafts.get(sessionId);
    const initial = memDraft !== undefined ? memDraft : (serverDraft ?? "");
    setText(initial);
    lastServerDraftRef.current = serverDraft ?? "";
    // Trigger a save if there's content — handles the case where the previous
    // session had onSaveDraft=undefined (e.g. virtual draft tid=0) and its
    // debounce was cancelled, leaving unsaved text.
    if (initial) saveDraftDebounced(initial);
    return () => {
      drafts.set(sessionId, textRef.current);
      saveDraftDebounced.cancel();
    };
  }, [sessionId]);

  // Apply incoming draft_updated from other clients if local text hasn't diverged
  useEffect(() => {
    if (serverDraft === undefined) return;
    const localText = textRef.current;
    if (localText === "" || localText === lastServerDraftRef.current) {
      setText(serverDraft);
      drafts.set(sessionId, serverDraft);
    }
    lastServerDraftRef.current = serverDraft;
  }, [serverDraft]);

  useEffect(() => {
    if (!insertTextRef) return;
    insertTextRef.current = (quoted: string) => {
      const prev = textRef.current;
      handleChange(prev ? `${prev.trimEnd()}\n\n${quoted}` : quoted);
      textareaRef.current?.focus();
      requestAnimationFrame(() => {
        if (textareaRef.current)
          textareaRef.current.scrollTop = textareaRef.current.scrollHeight;
      });
    };
    return () => {
      insertTextRef.current = null;
    };
  }, [insertTextRef]);

  useLayoutEffect(() => {
    if (!pasteTextRef) return;
    pasteTextRef.current = (pasted: string) => {
      const ta = textareaRef.current;
      const start = ta?.selectionStart ?? 0;
      const end = ta?.selectionEnd ?? 0;
      const prev = textRef.current;
      handleChange(prev.slice(0, start) + pasted + prev.slice(end));
      requestAnimationFrame(() => {
        if (ta) {
          const pos = start + pasted.length;
          ta.selectionStart = pos;
          ta.selectionEnd = pos;
        }
      });
      ta?.focus();
    };
    return () => {
      pasteTextRef.current = null;
    };
  }, [pasteTextRef]);

  useLayoutEffect(() => {
    if (supportsFieldSizing) return;
    const ta = textareaRef.current;
    if (!ta) return;
    ta.style.height = "0";
    ta.style.height = `${ta.scrollHeight}px`;
  }, [text]);

  // Pre-fill with unsaved user messages recovered after session reload
  useEffect(() => {
    if (!inputDraft) return;
    setText((prev) => (prev ? inputDraft + "\n\n" + prev : inputDraft));
    onInputDraftConsumed?.();
  }, [inputDraft]);

  const handleChange = (newText: string) => {
    const wasEmpty = textRef.current.trim() === "";
    const isEmpty = newText.trim() === "";
    setText(newText);
    drafts.set(sessionId, newText);
    saveDraftDebounced(newText);
    if (wasEmpty && !isEmpty) onContentStart?.();
    if (!wasEmpty && isEmpty) onContentEnd?.();
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

  const processFile = (file: File) => {
    if (!file.type.startsWith("image/")) return;
    const reader = new FileReader();
    reader.readAsDataURL(file);
    reader.onload = (e) => {
      const dataURL = e.target!.result as string;
      const base64 = dataURL.split(",")[1] ?? "";
      setImages((prev) => [
        ...prev,
        { id: crypto.randomUUID(), dataURL, base64, mediaType: file.type },
      ]);
    };
  };

  const handlePaste = (e: ClipboardEvent) => {
    const items = e.clipboardData?.items;
    if (!items) return;
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (!item) continue;
      if (item.kind === "file" && item.type.startsWith("image/")) {
        e.preventDefault();
        const file = item.getAsFile();
        if (file) processFile(file);
      }
    }
  };

  const handleDragOver = (e: DragEvent) => {
    if (!e.dataTransfer?.types.includes("Files")) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
    setIsDragging(true);
  };

  const handleDragLeave = (e: DragEvent) => {
    if (e.currentTarget === e.target) setIsDragging(false);
  };

  const handleDrop = (e: DragEvent) => {
    setIsDragging(false);
    const files = e.dataTransfer?.files;
    if (!files || files.length === 0) return;
    e.preventDefault();
    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      if (file) processFile(file);
    }
  };

  const send = () => {
    const trimmed = text.trim();
    if (!trimmed && images.length === 0) return;
    // Clear text eagerly: onSend may trigger a re-render that unmounts this
    // InputBox (e.g. draft → active transition).  Without this, the cleanup
    // function saves stale text to `drafts` because setState hasn't flushed.
    setText("");
    textRef.current = "";
    setImages([]);
    drafts.set(sessionId, "");
    saveDraftDebounced.cancel();
    onSaveDraft?.("");
    onSend(trimmed, images.length > 0 ? images : undefined);
    textareaRef.current?.focus();
  };

  return (
    <div
      class={`input-box${isDragging ? " input-box-dragging" : ""}`}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
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
      {images.length > 0 && (
        <div class="image-previews">
          {images.map((img) => (
            <div key={img.id} class="image-preview">
              <img src={img.dataURL} alt="Attached" />
              <button
                class="image-preview-remove"
                onClick={() => {
                  setImages((prev) => prev.filter((i) => i.id !== img.id));
                }}
                aria-label="Remove image"
              >
                ×
              </button>
            </div>
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
        onPaste={handlePaste}
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
        disabled={disabled || (!text.trim() && images.length === 0)}
      >
        Send
      </button>
    </div>
  );
}
