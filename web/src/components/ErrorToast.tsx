interface ErrorEntry {
  id: number;
  message: string;
  timestamp: number;
}

interface Props {
  errors: ErrorEntry[];
  onDismiss: (id: number) => void;
  onClearAll: () => void;
}

export function ErrorToast({ errors, onDismiss, onClearAll }: Props) {
  if (errors.length === 0) return null;

  return (
    <div class="error-toast-container">
      <div class="error-toast-header">
        <span>Uncaught errors ({errors.length})</span>
        <button class="error-toast-clear" onClick={onClearAll}>
          Clear all
        </button>
      </div>
      {errors.map((err) => (
        <div key={err.id} class="error-toast-item">
          <pre class="error-toast-message">{err.message}</pre>
          <button
            class="error-toast-dismiss"
            onClick={() => {
              onDismiss(err.id);
            }}
          >
            &times;
          </button>
        </div>
      ))}
    </div>
  );
}
