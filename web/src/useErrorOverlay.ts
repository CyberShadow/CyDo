import { useCallback, useEffect, useRef, useState } from "preact/hooks";

interface ErrorEntry {
  id: number;
  message: string;
  timestamp: number;
}

let counter = 0;

export function useErrorOverlay() {
  const [errors, setErrors] = useState<ErrorEntry[]>([]);
  const setErrorsRef = useRef(setErrors);
  setErrorsRef.current = setErrors;

  useEffect(() => {
    const onError = (e: ErrorEvent) => {
      const message =
        e.error instanceof Error ? e.error.message : String(e.message);
      setErrorsRef.current((prev) =>
        [...prev, { id: ++counter, message, timestamp: Date.now() }].slice(-5),
      );
    };
    const onUnhandledRejection = (e: PromiseRejectionEvent) => {
      const message =
        e.reason instanceof Error ? e.reason.message : String(e.reason);
      setErrorsRef.current((prev) =>
        [...prev, { id: ++counter, message, timestamp: Date.now() }].slice(-5),
      );
    };
    window.addEventListener("error", onError);
    window.addEventListener("unhandledrejection", onUnhandledRejection);
    return () => {
      window.removeEventListener("error", onError);
      window.removeEventListener("unhandledrejection", onUnhandledRejection);
    };
  }, []);

  const dismissError = useCallback((id: number) => {
    setErrors((prev) => prev.filter((e) => e.id !== id));
  }, []);

  const clearErrors = useCallback(() => {
    setErrors([]);
  }, []);

  return { errors, dismissError, clearErrors };
}
