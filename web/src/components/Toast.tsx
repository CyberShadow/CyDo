import { useEffect } from "preact/hooks";
import closeIcon from "../icons/close.svg?raw";
import type { ToastEntry } from "../useToast";

interface ItemProps {
  entry: ToastEntry;
  onDismiss: (id: number) => void;
}

function ToastItem({ entry, onDismiss }: ItemProps) {
  useEffect(() => {
    const timer = setTimeout(() => {
      onDismiss(entry.id);
    }, 8000);
    return () => {
      clearTimeout(timer);
    };
  }, [entry.id, onDismiss]);

  return (
    <div class={`toast-item toast-item-${entry.level}`}>
      <pre class="toast-message">{entry.message}</pre>
      <button
        class="toast-dismiss"
        onClick={() => {
          onDismiss(entry.id);
        }}
      >
        <span
          class="action-icon"
          dangerouslySetInnerHTML={{ __html: closeIcon }}
        />
      </button>
    </div>
  );
}

interface Props {
  toasts: ToastEntry[];
  onDismiss: (id: number) => void;
  onClearAll: () => void;
}

export function Toast({ toasts, onDismiss, onClearAll }: Props) {
  if (toasts.length === 0) return null;

  return (
    <div class="toast-container">
      <div class="toast-header">
        <span>Notifications ({toasts.length})</span>
        <button class="toast-clear" onClick={onClearAll}>
          Clear all
        </button>
      </div>
      {toasts.map((entry) => (
        <ToastItem key={entry.id} entry={entry} onDismiss={onDismiss} />
      ))}
    </div>
  );
}
