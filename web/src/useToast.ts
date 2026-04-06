import { useCallback, useState } from "preact/hooks";

export interface ToastEntry {
  id: number;
  level: "info" | "warning" | "error" | "alert";
  message: string;
  timestamp: number;
}

let counter = 0;

export function useToast() {
  const [toasts, setToasts] = useState<ToastEntry[]>([]);

  const addToast = useCallback(
    (level: ToastEntry["level"], message: string) => {
      setToasts((prev) =>
        [
          ...prev,
          { id: ++counter, level, message, timestamp: Date.now() },
        ].slice(-10),
      );
    },
    [],
  );

  const dismissToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const clearToasts = useCallback(() => {
    setToasts([]);
  }, []);

  return { toasts, addToast, dismissToast, clearToasts };
}
