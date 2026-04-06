import { useEffect, useRef } from "preact/hooks";
import type { ToastEntry } from "./useToast";

export function useErrorCapture(
  addToast: (level: ToastEntry["level"], message: string) => void,
) {
  const addToastRef = useRef(addToast);
  addToastRef.current = addToast;

  useEffect(() => {
    const onError = (e: ErrorEvent) => {
      const message = e.error instanceof Error ? e.error.message : e.message;
      addToastRef.current("error", message);
    };
    const onUnhandledRejection = (e: PromiseRejectionEvent) => {
      const message =
        e.reason instanceof Error ? e.reason.message : String(e.reason);
      addToastRef.current("error", message);
    };
    window.addEventListener("error", onError);
    window.addEventListener("unhandledrejection", onUnhandledRejection);
    return () => {
      window.removeEventListener("error", onError);
      window.removeEventListener("unhandledrejection", onUnhandledRejection);
    };
  }, []);
}
