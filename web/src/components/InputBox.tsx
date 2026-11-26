import { RefObject } from "preact";
import {
  useState,
  useRef,
  useEffect,
  useLayoutEffect,
  useMemo,
  useCallback,
} from "preact/hooks";
import type { ImageAttachment } from "../draftReconciler";
import { isHeicType, sniffImageType } from "../imageSniff";
import type { HeicConversionStatus } from "../protocol";
import {
  invalidateControlledImageEntry,
  publishControlledImageEntry,
  type ControlledImageEntry,
  type ControlledImageStore,
} from "../controlledImageStore";
import type { OrdinaryDraftStore } from "../ordinaryDraftStore";
import { applyRecoveredInputDraft } from "./inputDraft";

const supportsFieldSizing = CSS.supports("field-sizing", "content");

interface CommonProps {
  heicConversion: HeicConversionStatus;
  getHeicConversion: () => HeicConversionStatus;
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
    refusals: [],
    listeners: new Set(),
  };
  store.entries.set(key, entry);
  if (existing) invalidateControlledImageEntry(existing, false);
  return entry;
}

const SUPPORTED_IMAGE_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp",
]);

function useImageAttachments(
  enabled: boolean,
  getHeicConversion: () => HeicConversionStatus,
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
  const [localImages, setLocalImages] = useState<ImageAttachment[]>([]);
  const [localImagesGeneration, setLocalImagesGeneration] = useState(0);
  const [localRefusals, setLocalRefusals] = useState<readonly string[]>([]);
  const [, setEntryVersion] = useState(0);
  const [isDragging, setIsDragging] = useState(false);
  const enabledRef = useRef(enabled);
  const ownerIdentity = useRef({ resetToken, imageKey });
  const localGeneration = useRef(0);
  const localImagesRef = useRef(localImages);
  const invalidatedRef = useRef(false);

  const reset =
    !imageEntry &&
    (ownerIdentity.current.resetToken !== resetToken ||
      (!imageStore && ownerIdentity.current.imageKey !== imageKey));
  if (reset || enabledRef.current !== enabled) {
    if (imageEntry) {
      imageEntry.generation++;
    } else {
      localGeneration.current++;
      if (reset) localImagesRef.current = [];
    }
    invalidatedRef.current = true;
  }
  enabledRef.current = enabled;
  ownerIdentity.current = { resetToken, imageKey };

  const entryImages = imageEntry?.images;
  const entryRefusals = imageEntry?.refusals;
  useLayoutEffect(() => {
    if (!imageEntry) return;
    const receive = () => {
      setEntryVersion((version) => version + 1);
    };
    imageEntry.listeners.add(receive);
    if (
      entryImages !== imageEntry.images ||
      entryRefusals !== imageEntry.refusals
    )
      receive();
    return () => {
      imageEntry.listeners.delete(receive);
    };
  }, [imageEntry]);

  useLayoutEffect(() => {
    if (!invalidatedRef.current) return;
    invalidatedRef.current = false;
    if (imageEntry) {
      publishControlledImageEntry(imageEntry, imageEntry.images, []);
    } else {
      setLocalImages(localImagesRef.current);
      setLocalRefusals([]);
      setLocalImagesGeneration(localGeneration.current);
    }
    setIsDragging(false);
  }, [enabled, imageEntry, resetToken, imageKey]);

  const clearRefusals = () => {
    if (imageEntry) {
      if (imageStore!.entries.get(imageKey!) !== imageEntry) return;
      publishControlledImageEntry(imageEntry, imageEntry.images, []);
      return;
    }
    setLocalRefusals([]);
  };

  const setImages = (
    next:
      | ImageAttachment[]
      | ((previous: ImageAttachment[]) => ImageAttachment[]),
  ) => {
    if (imageEntry) {
      if (imageStore!.entries.get(imageKey!) !== imageEntry) return;
      const resolved =
        typeof next === "function" ? next(imageEntry.images) : next;
      publishControlledImageEntry(imageEntry, resolved, imageEntry.refusals);
      return;
    }
    const resolved =
      typeof next === "function" ? next(localImagesRef.current) : next;
    localImagesRef.current = resolved;
    setLocalImages(resolved);
  };

  const readFile = (file: File) =>
    new Promise<string | null>((resolve) => {
      const reader = new FileReader();
      reader.onload = (event) => {
        resolve(event.target!.result as string);
      };
      reader.onerror = reader.onabort = () => {
        resolve(null);
      };
      reader.readAsDataURL(file);
    });

  const attachFiles = async (files: FileList | File[]) => {
    if (!enabledRef.current || files.length === 0) return;
    const entry = imageEntry;
    const generation = entry?.generation ?? localGeneration.current;
    const isCurrent = () =>
      entry
        ? imageStore!.entries.get(imageKey!) === entry &&
          entry.generation === generation
        : generation === localGeneration.current;

    clearRefusals();
    const batch = await Promise.all(
      Array.from(files, async (file) => ({
        file,
        type:
          !file.type ||
          file.type === "application/octet-stream" ||
          isHeicType(file.type)
            ? await sniffImageType(file)
            : file.type,
      })),
    );
    if (!isCurrent()) return;

    const results = await Promise.all(
      batch.map(async ({ file, type }) => {
        const validType =
          type === "image/heic" ||
          (type && !isHeicType(file.type) && SUPPORTED_IMAGE_TYPES.has(type));
        return {
          file,
          type,
          dataURL: validType ? await readFile(file) : undefined,
        };
      }),
    );
    if (!isCurrent()) return;

    const conversion = getHeicConversion();
    const unsupported: string[] = [];
    const refused: string[] = [];
    const attachments: ImageAttachment[] = [];
    for (const { file, type, dataURL } of results) {
      if (type === undefined || dataURL === null) {
        refused.push(`Could not read ${file.name}.`);
      } else if (isHeicType(file.type) && type !== "image/heic") {
        refused.push(
          `${file.name} cannot be attached: not a HEIC/HEIF still image.`,
        );
      } else if (type === "image/heic" && !conversion.available) {
        refused.push(
          `${file.name} (HEIC) cannot be attached: HEIC conversion is unavailable on this server: ${conversion.reason}`,
        );
      } else if (type !== null && dataURL !== undefined) {
        const base64 = dataURL.split(",")[1]!;
        attachments.push({
          id: crypto.randomUUID(),
          name: file.name,
          dataURL: `data:${type};base64,${base64}`,
          base64,
          mediaType: type,
        });
      } else {
        unsupported.push(file.type ? `${file.name} (${file.type})` : file.name);
      }
    }
    if (unsupported.length) {
      const formats = conversion.available
        ? "JPEG, PNG, GIF, WebP, or HEIC"
        : "JPEG, PNG, GIF, or WebP";
      refused.push(`Cannot attach ${unsupported.join(", ")}. Use ${formats}.`);
    }
    if (entry) {
      publishControlledImageEntry(
        entry,
        [...entry.images, ...attachments],
        [...entry.refusals, ...refused],
      );
      return;
    }
    setImages((previous) => [...previous, ...attachments]);
    setLocalImagesGeneration(generation);
    setLocalRefusals((previous) => [...previous, ...refused]);
  };

  const addFiles = (files: FileList | File[]) => {
    void attachFiles(files).catch((error: unknown) => {
      queueMicrotask(() => {
        throw new Error("Attachment intake failed", { cause: error });
      });
    });
  };

  const onPaste = (event: ClipboardEvent) => {
    const items = event.clipboardData?.items;
    if (!items) return;
    const files: File[] = [];
    for (const item of Array.from(items)) {
      if (item.kind !== "file") continue;
      event.preventDefault();
      const file = item.getAsFile();
      if (file) files.push(file);
    }
    addFiles(files);
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
    addFiles(files);
  };

  return {
    images:
      entryImages ??
      (localImagesGeneration === localGeneration.current
        ? localImages
        : localImagesRef.current),
    setImages,
    isDragging: enabled && isDragging,
    addFiles,
    refusals: entryRefusals ?? localRefusals,
    clearRefusals,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  };
}

function AttachButton({
  disabled,
  heicAvailable,
  onFiles,
}: {
  disabled: boolean;
  heicAvailable: boolean;
  onFiles: (files: FileList) => void;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  return (
    <>
      <input
        ref={inputRef}
        class="input-file"
        type="file"
        accept={heicAvailable ? "image/*,.heic,.heif" : "image/*"}
        multiple
        disabled={disabled}
        tabIndex={-1}
        aria-hidden="true"
        onChange={(event) => {
          const input = event.currentTarget;
          onFiles(input.files!);
          input.value = "";
        }}
      />
      <button
        type="button"
        class="btn btn-attach"
        title="Attach images"
        aria-label="Attach images"
        disabled={disabled}
        onClick={() => {
          inputRef.current!.click();
        }}
      >
        <svg
          viewBox="5 0 14 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M17 5.75v10.85a5 5 0 0 1-10 0V5.75a3.35 3.35 0 0 1 6.7 0v10.85a1.65 1.65 0 0 1-3.3 0V6.6" />
        </svg>
      </button>
    </>
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
          {isHeicType(image.mediaType) ? (
            <span class="image-preview-label">HEIC {image.name}</span>
          ) : (
            <img src={image.dataURL} alt="Attached" />
          )}
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
  heicConversion,
  getHeicConversion,
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
    addFiles,
    refusals,
    clearRefusals,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  } = useImageAttachments(
    !disabled && !stdinClosed,
    getHeicConversion,
    undefined,
    undefined,
    sessionId,
  );

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

  const sendMessage: OrdinaryProps["onSend"] = (...args) => {
    clearRefusals();
    onSend(...args);
  };

  const send = () => {
    if (!draftActive.current) return;
    const trimmed = text.trim();
    if (!trimmed && images.length === 0) return;
    writeText("");
    setImages([]);
    saveDraftDebounced.cancel();
    onSaveDraft?.("");
    sendMessage(trimmed, images.length > 0 ? images : undefined);
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
                    sendMessage(suggestion);
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
      {refusals.length > 0 && (
        <div key="attach-error" class="attach-error" role="status">
          {refusals.join(" ")}
        </div>
      )}
      <textarea
        key="textarea"
        ref={textareaRef}
        class="text-input input-textarea"
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
      <AttachButton
        key="attach"
        disabled={disabled || !!stdinClosed}
        heicAvailable={heicConversion.available}
        onFiles={addFiles}
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
  heicConversion,
  getHeicConversion,
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
    addFiles,
    refusals,
    clearRefusals,
    onPaste,
    onDragOver,
    onDragLeave,
    onDrop,
  } = useImageAttachments(
    !disabled && !stdinClosed,
    getHeicConversion,
    composerResetToken,
    imageStore,
    imageKey,
  );
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
    clearRefusals();
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
      {refusals.length > 0 && (
        <div key="attach-error" class="attach-error" role="status">
          {refusals.join(" ")}
        </div>
      )}
      <textarea
        key="textarea"
        ref={textareaRef}
        class="text-input input-textarea"
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
      <AttachButton
        key="attach"
        disabled={disabled || !!stdinClosed}
        heicAvailable={heicConversion.available}
        onFiles={addFiles}
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
