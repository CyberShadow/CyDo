import { RefObject } from "preact";
import {
  useState,
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
} from "preact/hooks";
import type { ImageAttachment } from "../useSessionManager";
import { applyRecoveredInputDraft } from "./inputDraft";

export const drafts = new Map<string, string>();

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
  onSaveDraft?: (text: string) => void;
  suggestions?: string[];
}

interface ControlledProps extends CommonProps {
  mode: "controlled";
  value: string;
  onChange: (value: string) => void;
  onBlur: () => void;
  onSubmit: (text: string, images: ImageAttachment[]) => void;
  submitDisabled?: boolean;
  composerResetToken: number;
  imageStore?: ControlledImageStore;
  imageKey?: string;
}

export type InputBoxProps = OrdinaryProps | ControlledProps;

export interface ControlledImageEntry {
  resetToken: number;
  generation: number;
  images: ImageAttachment[];
  listeners: Set<(images: ImageAttachment[], generation: number) => void>;
}

export interface ControlledImageStore {
  entries: Map<string, ControlledImageEntry>;
}

export function createControlledImageStore(): ControlledImageStore {
  return { entries: new Map() };
}

function invalidateControlledImageEntry(
  entry: ControlledImageEntry,
  notify = true,
) {
  entry.generation++;
  entry.images = [];
  if (notify) {
    for (const listener of entry.listeners) {
      listener([], entry.generation);
    }
  }
  entry.listeners.clear();
}

export function resetControlledImageStore(store: ControlledImageStore) {
  const entries = Array.from(store.entries.values());
  store.entries.clear();
  for (const entry of entries) {
    invalidateControlledImageEntry(entry);
  }
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

// what the agent APIs actually accept; an iPhone photo arrives as JPEG because
// the picker transcodes it, but a file picked out of Files can still be HEIC,
// and attaching one silently produces a send the API rejects
const SUPPORTED_IMAGE_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
]);

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
  const [attachError, setAttachError] = useState<string | null>(null);
  const enabledRef = useRef(enabled);
  const resetTokenRef = useRef(resetToken);
  const generationRef = useRef(imageEntry?.generation ?? 0);
  const imagesRef = useRef(images);
  const invalidatedRef = useRef(false);

  const wasEnabled = enabledRef.current;
  if (resetTokenRef.current !== resetToken || wasEnabled !== enabled) {
    generationRef.current =
      (imageEntry?.generation ?? generationRef.current) + 1;
    if (imageEntry) {
      imageEntry.generation = generationRef.current;
      imageEntry.images = [];
    }
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
    const next: ImageAttachment[] = [];
    imagesRef.current = next;
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
    if (!SUPPORTED_IMAGE_TYPES.has(file.type)) {
      setAttachError(
        `${file.type} images can't be attached; JPEG, PNG, GIF and WebP work`,
      );
      return;
    }
    setAttachError(null);
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

  const addFiles = (files: FileList | File[] | null) => {
    if (!files) return;
    for (const file of Array.from(files)) processFile(file);
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
    images: enabled && imagesGeneration === generationRef.current ? images : [],
    setImages,
    isDragging: enabled && isDragging,
    attachError,
    dismissAttachError: () => {
      setAttachError(null);
    },
    addFiles,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  };
}

/** Attach button plus the hidden input it drives.
 *
 * Paste and drag-and-drop were the only ways to attach an image, and a phone
 * has neither: iOS has no file drag source, and gecko-for-iOS does not put
 * pasted photos on the DOM clipboard. A plain file input is what reaches the
 * system photo picker there.
 *
 * The input is visually hidden rather than display:none, since only the former
 * is reliably clickable programmatically across engines.
 */
function AttachButton({
  disabled,
  onFiles,
}: {
  disabled: boolean;
  onFiles: (files: FileList | null) => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  return (
    <>
      <input
        ref={inputRef}
        class="input-file"
        type="file"
        accept="image/*"
        multiple
        tabIndex={-1}
        aria-hidden="true"
        onChange={(event) => {
          const input = event.target as HTMLInputElement;
          onFiles(input.files);
          // clearing lets the same photo be picked again right after removing it
          input.value = "";
        }}
      />
      <button
        key="attach"
        class="btn btn-attach"
        title="Attach images"
        aria-label="Attach images"
        disabled={disabled}
        onClick={() => inputRef.current?.click()}
      >
        {/* drawn rather than typed: an emoji is a font glyph, so its artwork
            changes per platform and its advance width adds side bearings that
            no padding rule can reclaim */}
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M21.44 11.05 12.25 20.24a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
        </svg>
      </button>
    </>
  );
}

function AttachError({
  message,
  onDismiss,
}: {
  message: string;
  onDismiss: () => void;
}) {
  return (
    <div class="attach-error" role="status" onClick={onDismiss}>
      {message}
    </div>
  );
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
  onSaveDraft,
  inputRef,
  insertTextRef,
  pasteTextRef,
  onEscape,
  suggestions,
}: OrdinaryProps) {
  const [text, setText] = useState(() => {
    const memoryDraft = drafts.get(sessionId);
    if (memoryDraft !== undefined) return memoryDraft;
    return serverDraft ?? "";
  });
  const {
    images,
    setImages,
    isDragging,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
    attachError,
    dismissAttachError,
    addFiles,
  } = useImageAttachments();
  const internalRef = useRef<HTMLTextAreaElement>(null);
  const textareaRef = inputRef ?? internalRef;
  const textRef = useRef(text);
  const lastServerDraftRef = useRef<string>(serverDraft ?? "");

  const applyText = (next: string) => {
    textRef.current = next;
    setText(next);
  };

  const saveDraftDebounced = useMemo(
    () => debounce((draft: string) => onSaveDraft?.(draft), 500),
    [onSaveDraft],
  );
  const previousOnSaveDraft = useRef(onSaveDraft);

  useEffect(() => {
    const previous = previousOnSaveDraft.current;
    previousOnSaveDraft.current = onSaveDraft;
    if (!previous && onSaveDraft && textRef.current) {
      onSaveDraft(textRef.current);
    }
  }, [onSaveDraft]);

  useEffect(() => {
    const memoryDraft = drafts.get(sessionId);
    const initial =
      memoryDraft !== undefined ? memoryDraft : (serverDraft ?? "");
    applyText(initial);
    lastServerDraftRef.current = serverDraft ?? "";
    if (initial) saveDraftDebounced(initial);
    return () => {
      drafts.set(sessionId, textRef.current);
      saveDraftDebounced.cancel();
    };
  }, [sessionId]);

  useEffect(() => {
    const incoming = serverDraft ?? "";
    const localText = textRef.current;
    if (localText === "" || localText === lastServerDraftRef.current) {
      applyText(incoming);
      drafts.set(sessionId, incoming);
    }
    lastServerDraftRef.current = incoming;
  }, [serverDraft]);

  const handleChange = (next: string) => {
    applyText(next);
    drafts.set(sessionId, next);
    saveDraftDebounced(next);
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
    if (!inputDraft) return;
    const next = applyRecoveredInputDraft(inputDraft, textRef.current);
    if (next !== textRef.current) {
      applyText(next);
      drafts.set(sessionId, next);
    }
    onInputDraftConsumed?.();
  }, [inputDraft, onInputDraftConsumed, sessionId]);

  const send = () => {
    const trimmed = text.trim();
    if (!trimmed && images.length === 0) return;
    applyText("");
    setImages([]);
    drafts.set(sessionId, "");
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
      {attachError && (
        <AttachError message={attachError} onDismiss={dismissAttachError} />
      )}
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
      <AttachButton disabled={disabled || !!stdinClosed} onFiles={addFiles} />
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
  onBlur,
  onSubmit,
  submitDisabled = false,
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
    attachError,
    dismissAttachError,
    addFiles,
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
    const attachments = images;
    setImages([]);
    onSubmit(text, attachments);
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
      {attachError && (
        <AttachError message={attachError} onDismiss={dismissAttachError} />
      )}
      <textarea
        key="textarea"
        ref={textareaRef}
        class="input-textarea"
        value={value}
        onInput={(event) => {
          change((event.target as HTMLTextAreaElement).value);
        }}
        onBlur={onBlur}
        onKeyDown={handleKeyDown}
        onPaste={onPaste}
        placeholder={inputPlaceholder({ stdinClosed, disabled, isProcessing })}
        disabled={disabled}
        rows={1}
      />
      <AttachButton disabled={disabled || !!stdinClosed} onFiles={addFiles} />
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
        Send
      </button>
    </div>
  );
}
