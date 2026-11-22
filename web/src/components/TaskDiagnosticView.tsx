import type { HookOutput } from "../types";
import { Markdown } from "./Markdown";

export function TaskDiagnosticView({
  severity,
  subject,
  body,
  hookOutput,
}: {
  severity: "info" | "warning" | "error";
  subject: string;
  body: string;
  hookOutput?: HookOutput;
}) {
  if (severity === "info")
    return (
      <div class="message system-status-message diagnostic-message diagnostic-info">
        <div class="system-message-label">{subject}</div>
        <Markdown text={body} />
      </div>
    );
  const blockClass = severity === "error" ? "error-block" : "warning-block";
  const labelClass =
    severity === "error" ? "error-block-label" : "warning-block-label";
  const { stdout, stderr, output } = hookOutput ?? {};
  // Some hooks use output for a separate diagnostic. Render it only when it
  // differs from both streams, which always retain their own labels.
  const streams = [
    { label: "stdout", text: stdout },
    { label: "stderr", text: stderr },
    {
      label: "output",
      text: output !== stdout && output !== stderr ? output : undefined,
    },
  ].filter(
    (stream): stream is { label: string; text: string } => !!stream.text,
  );
  const longOutput =
    streams.reduce((length, { text }) => length + text.length + 1, -1) > 300 ||
    streams.reduce((lines, { text }) => lines + text.split("\n").length, 0) > 5;
  const streamBlocks = streams.map(({ label, text }) => (
    <div key={label}>
      <div>{label}</div>
      <pre>{text}</pre>
    </div>
  ));
  return (
    <div class={`diagnostic-message diagnostic-${severity}`}>
      <div class={blockClass}>
        <div class={labelClass}>{subject}</div>
        {hookOutput ? (
          longOutput ? (
            <details class="result-details">
              <summary>Hook output</summary>
              {streamBlocks}
            </details>
          ) : (
            streamBlocks
          )
        ) : (
          <Markdown text={body} />
        )}
      </div>
    </div>
  );
}
