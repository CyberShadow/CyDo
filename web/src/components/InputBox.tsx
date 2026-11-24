import { RefObject } from "preact";
import {
  useState,
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
  useCallback,
} from "preact/hooks";
import type { ImageAttachment } from "../useSessionManager";
import {
  invalidateControlledImageEntry,
  type ControlledImageEntry,
  type ControlledImageStore,
} from "../controlledImageStore";
import type { OrdinaryDraftStore } from "../ordinaryDraftStore";
import { applyRecoveredInputDraft } from "./inputDraft";

const supportsFieldSizing = CSS.supports("field-sizing", "content");

interface CommonProps {
  onInterrupt: () => void;
  isProcessing: boolean;
  stdinClosed?: boolean;
  disabled: boolean;
  inputRef?: RefObject<HTMLTextAreaElement>;
  insertTextRef?: RefObject<((text: string) => void) | null>;
  pasteTextRef?: RefObject<((text: string) => void) | null>;
  onEscape?: () => void;
}

interface OrdinaryProps extends CommonProps {
  mode?: "ordinary";
  onSend: (text: string, images?: ImageAttachment[]) => void;
  sessionId: string;
  inputDraft?: string;
  onInputDraftConsumed?: () => void;
  serverDraft?: string;
  ordinaryDraftStore: OrdinaryDraftStore;
  onSaveDraft?: (text: string) => void;
  suggestions?: string[];
}

interface ControlledProps extends CommonProps {
  mode: "controlled";
  value: string;
  onChange: (value: string) => void;
  onSubmit: (text: string, images: ImageAttachment[]) => void;
  submitDisabled?: boolean;
  submitLabel?: string;
  composerResetToken: number;
  imageStore?: ControlledImageStore;
  imageKey?: string;
}

export type InputBoxProps = OrdinaryProps | ControlledProps;

function debounce<A extends unknown[]>(
  fn: (...args: A) => void,
  ms: number,
): ((...args: A) => void) & { cancel: () => void; flush: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pendingArgs: A | null = null;

  const invoke = () => {
    const args = pendingArgs;
    timer = null;
    pendingArgs = null;
    if (args === null) throw new Error("Debounced call is missing arguments");
    fn(...args);
  };

  const debounced = (...args: A) => {
    if (timer !== null) clearTimeout(timer);
    pendingArgs = args;
    timer = setTimeout(() => {
      invoke();
    }, ms);
  };
  debounced.cancel = () => {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    pendingArgs = null;
  };
  debounced.flush = () => {
    if (timer === null) return;
    clearTimeout(timer);
    invoke();
  };
  return debounced;
}

function controlledImageEntry(
  store: ControlledImageStore,
  key: string,
  resetToken: number,
): ControlledImageEntry {
  const existing = store.entries.get(key);
  if (existing?.resetToken === resetToken) return existing;
  const entry: ControlledImageEntry = {
    resetToken,
    generation: existing ? existing.generation + 1 : 0,
    images: [],
    listeners: new Set(),
  };
  store.entries.set(key, entry);
  if (existing) invalidateControlledImageEntry(existing, false);
  return entry;
}

function publishImages(entry: ControlledImageEntry, images: ImageAttachment[]) {
  entry.images = images;
  for (const listener of entry.listeners) {
    listener(images, entry.generation);
  }
}

function useImageAttachments(
  enabled = true,
  resetToken?: number,
  imageStore?: ControlledImageStore,
  imageKey?: string,
) {
  const imageEntry =
    imageStore && imageKey !== undefined && resetToken !== undefined
      ? enabled || imageStore.entries.has(imageKey)
        ? controlledImageEntry(imageStore, imageKey, resetToken)
        : null
      : null;
  const [images, setImagesState] = useState<ImageAttachment[]>(
    () => imageEntry?.images ?? [],
  );
  const [imagesGeneration, setImagesGeneration] = useState(
    () => imageEntry?.generation ?? 0,
  );
  const [isDragging, setIsDragging] = useState(false);
  const enabledRef = useRef(enabled);
  const resetTokenRef = useRef(resetToken);
  const generationRef = useRef(imageEntry?.generation ?? 0);
  const imagesRef = useRef(images);
  const invalidatedRef = useRef(false);

  const reset = resetTokenRef.current !== resetToken;
  if (reset || enabledRef.current !== enabled) {
    generationRef.current =
      (imageEntry?.generation ?? generationRef.current) + 1;
    if (imageEntry) {
      imageEntry.generation = generationRef.current;
      if (reset) imageEntry.images = [];
    }
    if (reset) imagesRef.current = [];
    invalidatedRef.current = true;
  }
  enabledRef.current = enabled;
  resetTokenRef.current = resetToken;

  useLayoutEffect(() => {
    if (!imageEntry) return;
    const receive = (next: ImageAttachment[], generation: number) => {
      imagesRef.current = next;
      setImagesState(next);
      setImagesGeneration(generation);
    };
    imageEntry.listeners.add(receive);
    if (
      imagesRef.current !== imageEntry.images ||
      imagesGeneration !== imageEntry.generation
    )
      receive(imageEntry.images, imageEntry.generation);
    return () => {
      imageEntry.listeners.delete(receive);
    };
  }, [imageEntry]);

  useLayoutEffect(() => {
    if (!invalidatedRef.current) return;
    invalidatedRef.current = false;
    const next = imagesRef.current;
    if (imageEntry) publishImages(imageEntry, next);
    else setImagesState(next);
    setImagesGeneration(generationRef.current);
    setIsDragging(false);
  }, [enabled, imageEntry, resetToken]);

  const setImages = (
    next:
      | ImageAttachment[]
      | ((previous: ImageAttachment[]) => ImageAttachment[]),
  ) => {
    const resolved =
      typeof next === "function" ? next(imagesRef.current) : next;
    imagesRef.current = resolved;
    if (imageEntry) {
      if (imageStore?.entries.get(imageKey!) !== imageEntry) return;
      publishImages(imageEntry, resolved);
      return;
    }
    setImagesState(resolved);
  };

  const processFile = (file: File) => {
    if (!enabledRef.current || !file.type.startsWith("image/")) return;
    const generation = generationRef.current;
    const entry = imageEntry;
    const reader = new FileReader();
    reader.onload = (event) => {
      const dataURL = event.target!.result as string;
      const base64 = dataURL.split(",")[1] ?? "";
      const image = {
        id: crypto.randomUUID(),
        dataURL,
        base64,
        mediaType: file.type,
      };
      if (entry) {
        if (
          imageStore?.entries.get(imageKey!) !== entry ||
          entry.generation !== generation
        )
          return;
        publishImages(entry, [...entry.images, image]);
        return;
      }
      if (generation !== generationRef.current) return;
      setImages((previous) => [...previous, image]);
      setImagesGeneration(generation);
    };
    reader.readAsDataURL(file);
  };

  const onPaste = (event: ClipboardEvent) => {
    const items = event.clipboardData?.items;
    if (!items) return;
    if (!enabledRef.current) {
      for (let index = 0; index < items.length; index++) {
        const item = items[index];
        if (item?.kind === "file" && item.type.startsWith("image/")) {
          event.preventDefault();
          break;
        }
      }
      return;
    }
    for (let index = 0; index < items.length; index++) {
      const item = items[index];
      if (!item) continue;
      if (item.kind === "file" && item.type.startsWith("image/")) {
        event.preventDefault();
        const file = item.getAsFile();
        if (file) processFile(file);
      }
    }
  };

  const onDragOver = (event: DragEvent) => {
    if (!event.dataTransfer?.types.includes("Files")) return;
    event.preventDefault();
    if (!enabledRef.current) return;
    event.dataTransfer.dropEffect = "copy";
    setIsDragging(true);
  };

  const onDragLeave = (event: DragEvent) => {
    if (event.currentTarget === event.target) setIsDragging(false);
  };

  const onDrop = (event: DragEvent) => {
    setIsDragging(false);
    const files = event.dataTransfer?.files;
    if (!files || files.length === 0) return;
    event.preventDefault();
    if (!enabledRef.current) return;
    for (let index = 0; index < files.length; index++) {
      const file = files[index];
      if (file) processFile(file);
    }
  };

  return {
    images:
      imagesGeneration === generationRef.current ? images : imagesRef.current,
    setImages,
    isDragging: enabled && isDragging,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  };
}

function ImagePreviews({
  images,
  onRemove,
  disabled = false,
}: {
  images: ImageAttachment[];
  onRemove: (id: string) => void;
  disabled?: boolean;
}) {
  if (images.length === 0) return null;
  return (
    <div key="image-previews" class="image-previews">
      {images.map((image) => (
        <div key={image.id} class="image-preview">
          <img src={image.dataURL} alt="Attached" />
          <button
            class="image-preview-remove"
            onClick={() => {
              if (disabled) return;
              onRemove(image.id);
            }}
            aria-label="Remove image"
            disabled={disabled}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  );
}

function inputPlaceholder({
  stdinClosed,
  disabled,
  isProcessing,
}: Pick<CommonProps, "stdinClosed" | "disabled" | "isProcessing">) {
  return stdinClosed
    ? "Session ending..."
    : disabled
      ? "Connecting..."
      : isProcessing
        ? "Type a steering message..."
        : "Type a message...";
}

export function InputBox(props: InputBoxProps) {
  return props.mode === "controlled" ? (
    <ControlledInputBox {...props} />
  ) : (
    <OrdinaryInputBox {...props} />
  );
}

function OrdinaryInputBox({
  onSend,
  onInterrupt,
  isProcessing,
  stdinClosed,
  disabled,
  sessionId,
  inputDraft,
  onInputDraftConsumed,
  serverDraft,
  ordinaryDraftStore,
  onSaveDraft,
  inputRef,
  insertTextRef,
  pasteTextRef,
  onEscape,
  suggestions,
}: OrdinaryProps) {
  const [text, setText] = useState(
    () => ordinaryDraftStore.read(sessionId) ?? serverDraft ?? "",
  );
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const textRef = useRef(text);
  const draftActive = useRef(false);

  const applyText = useCallback((next: string) => {
    textRef.current = next;
    setText(next);
  }, []);

  const writeText = useCallback(
    (next: string) => {
      ordinaryDraftStore.write(sessionId, next);
    },
    [ordinaryDraftStore, sessionId],
  );

  const {
    images,
    setImages,
    isDragging,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  } = useImageAttachments();

  const saveDraftDebounced = useMemo(
    () =>
      debounce(() => {
        if (draftActive.current) onSaveDraft?.(textRef.current);
      }, 500),
    [onSaveDraft, ordinaryDraftStore, sessionId],
  );
  const previousOnSaveDraft = useRef(onSaveDraft);

  useLayoutEffect(() => {
    const flushDraft = () => {
      saveDraftDebounced.flush();
    };
    const invalidate = () => {
      draftActive.current = false;
      saveDraftDebounced.cancel();
      window.removeEventListener("pagehide", flushDraft);
    };
    ordinaryDraftStore.ensure(sessionId, serverDraft ?? "");
    const unregister = ordinaryDraftStore.register(
      sessionId,
      applyText,
      invalidate,
    );
    draftActive.current = true;
    window.addEventListener("pagehide", flushDraft);

    const previous = previousOnSaveDraft.current;
    previousOnSaveDraft.current = onSaveDraft;
    if (textRef.current) {
      if (!previous && onSaveDraft) onSaveDraft(textRef.current);
      else saveDraftDebounced();
    }

    return () => {
      flushDraft();
      invalidate();
      unregister();
    };
    // The snapshot seeds a new owner. Remote updates reach the registered listener.
  }, [
    applyText,
    onSaveDraft,
    ordinaryDraftStore,
    saveDraftDebounced,
    sessionId,
  ]);

  const handleChange = (next: string) => {
    if (!draftActive.current) return;
    writeText(next);
    saveDraftDebounced();
  };

  useEffect(() => {
    if (!insertTextRef) return;
    insertTextRef.current = (quoted: string) => {
      const previous = textRef.current;
      handleChange(previous ? `${previous.trimEnd()}\n\n${quoted}` : quoted);
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
      const textarea = textareaRef.current;
      const start = textarea?.selectionStart ?? 0;
      const end = textarea?.selectionEnd ?? 0;
      const previous = textRef.current;
      handleChange(previous.slice(0, start) + pasted + previous.slice(end));
      requestAnimationFrame(() => {
        if (textarea) {
          const position = start + pasted.length;
          textarea.selectionStart = position;
          textarea.selectionEnd = position;
        }
      });
      textarea?.focus();
    };
    return () => {
      pasteTextRef.current = null;
    };
  }, [pasteTextRef]);

  useEffect(() => {
    if (supportsFieldSizing) return;
    const textarea = textareaRef.current;
    if (!textarea) return;
    const handle = requestAnimationFrame(() => {
      textarea.style.height = "0";
      textarea.style.height = `${textarea.scrollHeight}px`;
    });
    return () => {
      cancelAnimationFrame(handle);
    };
  }, [text]);

  useEffect(() => {
    if (!inputDraft || !draftActive.current) return;
    const next = applyRecoveredInputDraft(inputDraft, textRef.current);
    if (next !== textRef.current) {
      writeText(next);
    }
    onInputDraftConsumed?.();
  }, [inputDraft, onInputDraftConsumed, sessionId]);

  const send = () => {
    if (!draftActive.current) return;
    const trimmed = text.trim();
    if (!trimmed && images.length === 0) return;
    writeText("");
    setImages([]);
    saveDraftDebounced.cancel();
    onSaveDraft?.("");
    onSend(trimmed, images.length > 0 ? images : undefined);
    textareaRef.current?.focus();
  };

  const handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      send();
    } else if (event.key === "Escape" && onEscape) {
      event.preventDefault();
      onEscape();
    }
  };

  return (
    <div
      class={`input-box${isDragging ? " input-box-dragging" : ""}`}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      {!isProcessing &&
        !text.trim() &&
        suggestions &&
        suggestions.length > 0 && (
          <div key="suggestions" class="suggestions">
            {suggestions.map((suggestion) => (
              <button
                key={suggestion}
                class="btn btn-suggestion"
                draggable
                onDragStart={(event) => {
                  event.dataTransfer!.setData("text/plain", suggestion);
                  event.dataTransfer!.effectAllowed = "copy";
                }}
                onClick={(event) => {
                  if (event.shiftKey) {
                    handleChange(suggestion);
                    textareaRef.current?.focus();
                  } else {
                    onSend(suggestion);
                  }
                }}
                title="Click to send, drag and drop to edit"
              >
                {suggestion}
              </button>
            ))}
          </div>
        )}
      <ImagePreviews
        images={images}
        disabled={disabled}
        onRemove={(id) => {
          setImages((previous) => previous.filter((image) => image.id !== id));
        }}
      />
      <textarea
        key="textarea"
        ref={textareaRef}
        class="input-textarea"
        value={text}
        onInput={(event) => {
          handleChange((event.target as HTMLTextAreaElement).value);
        }}
        onBlur={() => {
          onSaveDraft?.(textRef.current);
        }}
        onKeyDown={handleKeyDown}
        onPaste={onPaste}
        placeholder={inputPlaceholder({ stdinClosed, disabled, isProcessing })}
        disabled={disabled}
        rows={1}
      />
      {isProcessing && (
        <button key="stop" class="btn btn-stop" onClick={onInterrupt}>
          Stop
        </button>
      )}
      <button
        key="send"
        class="btn btn-send"
        onClick={send}
        disabled={
          disabled || !!stdinClosed || (!text.trim() && images.length === 0)
        }
      >
        Send
      </button>
    </div>
  );
}

function ControlledInputBox({
  onInterrupt,
  isProcessing,
  stdinClosed,
  disabled,
  value,
  onChange,
  onSubmit,
  submitDisabled = false,
  submitLabel = "Send",
  composerResetToken,
  imageStore,
  imageKey,
  inputRef,
  insertTextRef,
  pasteTextRef,
  onEscape,
}: ControlledProps) {
  const {
    images,
    setImages,
    isDragging,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  } = useImageAttachments(!disabled, composerResetToken, imageStore, imageKey);
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const valueRef = useRef(value);

  useLayoutEffect(() => {
    valueRef.current = value;
  }, [value]);

  const change = (next: string) => {
    valueRef.current = next;
    onChange(next);
  };

  useEffect(() => {
    if (!insertTextRef) return;
    insertTextRef.current = (quoted: string) => {
      const previous = valueRef.current;
      change(previous ? `${previous.trimEnd()}\n\n${quoted}` : quoted);
      textareaRef.current?.focus();
      requestAnimationFrame(() => {
        if (textareaRef.current)
          textareaRef.current.scrollTop = textareaRef.current.scrollHeight;
      });
    };
    return () => {
      insertTextRef.current = null;
    };
  }, [insertTextRef, onChange]);

  useLayoutEffect(() => {
    if (!pasteTextRef) return;
    pasteTextRef.current = (pasted: string) => {
      const textarea = textareaRef.current;
      const start = textarea?.selectionStart ?? 0;
      const end = textarea?.selectionEnd ?? 0;
      const previous = valueRef.current;
      change(previous.slice(0, start) + pasted + previous.slice(end));
      requestAnimationFrame(() => {
        if (textarea) {
          const position = start + pasted.length;
          textarea.selectionStart = position;
          textarea.selectionEnd = position;
        }
      });
      textarea?.focus();
    };
    return () => {
      pasteTextRef.current = null;
    };
  }, [pasteTextRef, onChange]);

  useEffect(() => {
    if (supportsFieldSizing) return;
    const textarea = textareaRef.current;
    if (!textarea) return;
    const handle = requestAnimationFrame(() => {
      textarea.style.height = "0";
      textarea.style.height = `${textarea.scrollHeight}px`;
    });
    return () => {
      cancelAnimationFrame(handle);
    };
  }, [value]);

  const submit = () => {
    if (disabled || submitDisabled) return;
    const text = valueRef.current.trim();
    if (!text && images.length === 0) return;
    onSubmit(text, [...images]);
    textareaRef.current?.focus();
  };

  const handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
    } else if (event.key === "Escape" && onEscape) {
      event.preventDefault();
      onEscape();
    }
  };

  return (
    <div
      class={`input-box${isDragging ? " input-box-dragging" : ""}`}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      <ImagePreviews
        images={images}
        disabled={disabled}
        onRemove={(id) => {
          setImages((previous) => previous.filter((image) => image.id !== id));
        }}
      />
      <textarea
        key="textarea"
        ref={textareaRef}
        class="input-textarea"
        value={value}
        onInput={(event) => {
          change((event.target as HTMLTextAreaElement).value);
        }}
        onKeyDown={handleKeyDown}
        onPaste={onPaste}
        placeholder={inputPlaceholder({ stdinClosed, disabled, isProcessing })}
        disabled={disabled}
        rows={1}
      />
      {isProcessing && (
        <button key="stop" class="btn btn-stop" onClick={onInterrupt}>
          Stop
        </button>
      )}
      <button
        key="send"
        class="btn btn-send"
        onClick={submit}
        disabled={
          disabled ||
          submitDisabled ||
          !!stdinClosed ||
          (!value.trim() && images.length === 0)
        }
      >
        {submitLabel}
      </button>
    </div>
  );
}
