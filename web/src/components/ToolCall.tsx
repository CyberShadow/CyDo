import { h } from "preact";
import { useState } from "preact/hooks";
import type { ToolResult } from "../app";

interface Props {
  name: string;
  input: Record<string, unknown>;
  result?: ToolResult;
}

export function ToolCall({ name, input, result }: Props) {
  const [inputOpen, setInputOpen] = useState(false);
  const [resultOpen, setResultOpen] = useState(false);

  return (
    <div class={`tool-call ${result?.isError ? "tool-error" : ""}`}>
      <div class="tool-header" onClick={() => setInputOpen(!inputOpen)}>
        <span class="tool-icon">{result ? (result.isError ? "!" : "\u2713") : "\u2026"}</span>
        <span class="tool-name">{name}</span>
        {!result && <span class="tool-spinner" />}
      </div>
      {inputOpen && (
        <pre class="tool-input">{JSON.stringify(input, null, 2)}</pre>
      )}
      {result && (
        <div class="tool-result-section">
          <div
            class="tool-result-header"
            onClick={() => setResultOpen(!resultOpen)}
          >
            {resultOpen ? "\u25BC" : "\u25B6"} Result
          </div>
          {resultOpen && (
            <pre class={`tool-result ${result.isError ? "error" : ""}`}>
              {result.content}
            </pre>
          )}
        </div>
      )}
    </div>
  );
}
