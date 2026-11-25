import { useEffect, useRef, useState } from "preact/hooks";
import { isPatchPath } from "../../lib/fileFormats";
import { useLiveFileAccess } from "../LocalFileContext";
import { DiffResult } from "../diff/DiffResult";
import { ResultImages } from "../ResultImages";
import { FileContentPreview } from "./FileContentPreview";

type LiveFileState =
  | { kind: "loading" }
  | { kind: "image"; dataUrl: string }
  | { kind: "text"; text: string }
  | { kind: "unavailable"; reason: string };

const loading: LiveFileState = { kind: "loading" };

function liveFileUrl(tid: number, path: string): string {
  return `/api/live-file?tid=${tid}&path=${encodeURIComponent(path)}`;
}

function useLiveFile(tid: number, path: string) {
  const placeholder = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<LiveFileState>(loading);

  useEffect(() => {
    setState(loading);
    const controller = new AbortController();
    let started = false;

    async function load(): Promise<LiveFileState> {
      const response = await fetch(liveFileUrl(tid, path), {
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) {
        return { kind: "unavailable", reason: await response.text() };
      }
      if (response.headers.get("Content-Type")?.startsWith("image/")) {
        const blob = await response.blob();
        const dataUrl = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => {
            resolve(reader.result as string);
          };
          reader.onerror = () => {
            reject(new Error(reader.error!.message));
          };
          reader.readAsDataURL(blob);
        });
        return { kind: "image", dataUrl };
      }
      return { kind: "text", text: await response.text() };
    }

    function finish(value: LiveFileState) {
      if (!controller.signal.aborted) setState(value);
    }

    const observer = new IntersectionObserver((entries) => {
      if (started || !entries.some((entry) => entry.isIntersecting)) return;
      started = true;
      observer.disconnect();
      void load().then(finish, (error: unknown) => {
        finish({
          kind: "unavailable",
          reason: error instanceof Error ? error.message : String(error),
        });
      });
    });
    observer.observe(placeholder.current!);
    return () => {
      observer.disconnect();
      controller.abort();
    };
  }, [tid, path]);

  return { placeholder, state };
}

export function LiveFilePreview({ path }: { path: string }) {
  const access = useLiveFileAccess(path);
  return access ? <LiveFileContent tid={access.tid} path={path} /> : null;
}

function LiveFileContent({ tid, path }: { tid: number; path: string }) {
  const { placeholder, state } = useLiveFile(tid, path);

  return (
    <div ref={placeholder} style={{ minHeight: "4rem" }}>
      {state.kind === "loading" && <div class="source-loading">Loading…</div>}
      {state.kind === "unavailable" && (
        <div class="source-loading">Unavailable: {state.reason}</div>
      )}
      {state.kind === "image" && <ResultImages srcs={[state.dataUrl]} />}
      {state.kind === "text" &&
        (isPatchPath(path) ? (
          <DiffResult content={state.text} />
        ) : (
          <FileContentPreview filePath={path} content={state.text} />
        ))}
    </div>
  );
}
