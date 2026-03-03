import { h, Fragment, ComponentChildren } from "preact";
import { useState } from "preact/hooks";
import type { ToolResult, ToolResultContent } from "../types";
import type { ThemedToken } from "../highlight";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { Markdown } from "./Markdown";

interface Props {
  name: string;
  input: Record<string, unknown>;
  result?: ToolResult;
  children?: ComponentChildren;
}

/** Render an array of token lines (no trailing newline). */
function renderTokenLines(tokens: ThemedToken[][]): h.JSX.Element {
  return (
    <Fragment>
      {tokens.map((line, i) => (
        <Fragment key={i}>
          {i > 0 && "\n"}
          {renderTokens(line)}
        </Fragment>
      ))}
    </Fragment>
  );
}

function DiffView({ oldStr, newStr, filePath }: { oldStr: string; newStr: string; filePath?: string }) {
  const lang = filePath ? langFromPath(filePath) : null;
  const oldTokens = useHighlight(oldStr, lang);
  const newTokens = useHighlight(newStr, lang);

  const oldLines = oldStr.split("\n");
  const newLines = newStr.split("\n");
  const minLen = Math.min(oldLines.length, newLines.length);

  let prefix = 0;
  for (let i = 0; i < minLen; i++) {
    if (oldLines[i] === newLines[i]) prefix++;
    else break;
  }

  let suffix = 0;
  for (let i = 0; i < minLen - prefix; i++) {
    if (oldLines[oldLines.length - 1 - i] === newLines[newLines.length - 1 - i]) suffix++;
    else break;
  }

  const oldEnd = oldLines.length - suffix;
  const newEnd = newLines.length - suffix;

  function line(idx: number, source: "old" | "new") {
    const tokens = source === "old" ? oldTokens : newTokens;
    const lines = source === "old" ? oldLines : newLines;
    return tokens?.[idx] ? renderTokens(tokens[idx]) : lines[idx];
  }

  return (
    <div class="diff-view">
      <div class="diff-header">@@ -{oldLines.length} +{newLines.length} @@</div>
      {oldLines.slice(0, prefix).map((_, i) => (
        <div key={`p${i}`} class="diff-context">{"  "}{line(i, "old")}</div>
      ))}
      {Array.from({ length: oldEnd - prefix }, (_, j) => {
        const i = prefix + j;
        return <div key={`r${i}`} class="diff-removed">{"- "}{line(i, "old")}</div>;
      })}
      {Array.from({ length: newEnd - prefix }, (_, j) => {
        const i = prefix + j;
        return <div key={`a${i}`} class="diff-added">{"+ "}{line(i, "new")}</div>;
      })}
      {oldLines.slice(oldEnd).map((_, j) => {
        const i = oldEnd + j;
        return <div key={`s${i}`} class="diff-context">{"  "}{line(i, "old")}</div>;
      })}
    </div>
  );
}

function EditInput({ input }: { input: Record<string, unknown> }) {
  const oldString = input.old_string as string;
  const newString = input.new_string as string;
  const filePath = typeof input.file_path === "string" ? input.file_path : undefined;
  const remaining = Object.entries(input).filter(
    ([k]) => !["file_path", "old_string", "new_string", "replace_all"].includes(k)
  );

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field"><span class="field-label">{k}:</span> <span class="field-value">{String(v)}</span></div>
      ))}
      <DiffView oldStr={oldString} newStr={newString} filePath={filePath} />
    </div>
  );
}

function WriteInput({ input }: { input: Record<string, unknown> }) {
  const content = input.content as string;
  const filePath = typeof input.file_path === "string" ? input.file_path : undefined;
  const lang = filePath ? langFromPath(filePath) : null;
  const tokens = useHighlight(content, lang);
  const remaining = Object.entries(input).filter(
    ([k]) => !["file_path", "content"].includes(k)
  );

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field"><span class="field-label">{k}:</span> <span class="field-value">{String(v)}</span></div>
      ))}
      <pre class="write-content">{tokens ? renderTokenLines(tokens) : content}</pre>
    </div>
  );
}

function BashInput({ input }: { input: Record<string, unknown> }) {
  const command = input.command as string;
  const tokens = useHighlight(command, "bash");
  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k !== "command" && k !== "description") remaining[k] = v;
  }

  return formatGenericInput(
    remaining,
    <pre class="write-content">{tokens ? renderTokenLines(tokens) : command}</pre>
  );
}

function ReadResult({ content, filePath }: { content: string; filePath: string }) {
  const rawLines = content.split("\n");
  // Parse cat -n format: "    1→code" (→ = U+2192) or "    1\tcode"
  const parsed = rawLines.map((line) => {
    const match = line.match(/^(\s*\d+[\u2192\t])(.*)/);
    if (match) return { prefix: match[1], code: match[2] };
    return { prefix: "", code: line };
  });

  const codeOnly = parsed.map((p) => p.code).join("\n");
  const lang = langFromPath(filePath);
  const tokens = useHighlight(codeOnly, lang);

  return (
    <pre class="tool-result">
      {parsed.map((p, i) => (
        <Fragment key={i}>
          {i > 0 && "\n"}
          {p.prefix && <span class="line-number">{p.prefix}</span>}
          {tokens?.[i] ? renderTokens(tokens[i]) : p.code}
        </Fragment>
      ))}
    </pre>
  );
}

interface TodoItem {
  content: string;
  status: string;
  activeForm?: string;
}

function formatTodoWriteInput(input: Record<string, unknown>): h.JSX.Element {
  const todos = input.todos as TodoItem[];
  const remaining = Object.entries(input).filter(([k]) => k !== "todos");

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field"><span class="field-label">{k}:</span> <span class="field-value">{String(v)}</span></div>
      ))}
      <div class="todo-list">
        {todos.map((item, i) => (
          <div key={i} class={`todo-item todo-${item.status}`}>
            <span class="todo-status">
              {item.status === "completed" ? "\u2713" : item.status === "in_progress" ? "\u25B6" : "\u25CB"}
            </span>
            <span class="todo-content">{item.content}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function formatGenericInput(input: Record<string, unknown>, children?: ComponentChildren): h.JSX.Element {
  const entries = Object.entries(input);
  return (
    <div class="tool-input-formatted">
      {entries.map(([k, v]) => {
        const str = typeof v === "string" ? v : JSON.stringify(v, null, 2);
        const isMultiline = str.includes("\n");
        return (
          <div key={k} class="tool-input-field">
            <span class="field-label">{k}:</span>
            {isMultiline
              ? <pre class="field-value-block">{str}</pre>
              : <span class="field-value"> {str}</span>
            }
          </div>
        );
      })}
      {children}
    </div>
  );
}

function getHeaderSubtitle(name: string, input: Record<string, unknown>): h.JSX.Element | null {
  const filePath = typeof input.file_path === "string" ? input.file_path : null;

  if (name === "Edit" && filePath) {
    return (
      <Fragment>
        <span class="tool-subtitle-path">{filePath}</span>
        {input.replace_all && <span class="tool-subtitle-tag">all</span>}
      </Fragment>
    );
  }
  if (name === "Write" && filePath) {
    return <span class="tool-subtitle-path">{filePath}</span>;
  }
  if (name === "Read" && filePath) {
    const offset = typeof input.offset === "number" ? input.offset : null;
    const limit = typeof input.limit === "number" ? input.limit : null;
    const range = offset != null && limit != null ? `(${offset}\u2013${offset + limit - 1})`
      : offset != null ? `(${offset}\u2013)`
      : limit != null ? `(1\u2013${limit})`
      : null;
    return (
      <Fragment>
        <span class="tool-subtitle-path">{filePath}</span>
        {range && <span class="tool-subtitle">{range}</span>}
      </Fragment>
    );
  }
  if (["Glob", "Grep"].includes(name) && typeof input.pattern === "string") {
    const path = typeof input.path === "string" ? input.path : null;
    return (
      <Fragment>
        <code class="tool-subtitle-pattern">{input.pattern}</code>
        {path && <Fragment>{" in "}<code class="tool-subtitle-path">{path}</code></Fragment>}
      </Fragment>
    );
  }
  if (name === "Bash" && typeof input.description === "string") {
    return <span class="tool-subtitle">{input.description}</span>;
  }
  if (name === "Task" && typeof input.description === "string") {
    const prefix = typeof input.subagent_type === "string" ? `${input.subagent_type}: ` : "";
    return <span class="tool-subtitle">{prefix}{input.description}</span>;
  }
  return null;
}

function formatInput(name: string, input: Record<string, unknown>): h.JSX.Element {
  if (name === "Edit" && "old_string" in input && "new_string" in input) {
    return <EditInput input={input} />;
  }
  if (name === "Write" && "file_path" in input && "content" in input) {
    return <WriteInput input={input} />;
  }
  if ((name === "TodoWrite" || "todos" in input) && Array.isArray(input.todos)) {
    return formatTodoWriteInput(input);
  }
  if (name === "ExitPlanMode" && typeof input.plan === "string") {
    const { plan, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={plan} />);
  }
  if (name === "Task" && typeof input.prompt === "string") {
    const { prompt, description, subagent_type, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={prompt} />);
  }
  if (name === "Bash" && typeof input.command === "string") {
    return <BashInput input={input} />;
  }
  if (name === "Read" && typeof input.file_path === "string") {
    const { file_path, offset, limit, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (["Glob", "Grep"].includes(name) && typeof input.pattern === "string") {
    const { pattern, path, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  return formatGenericInput(input);
}

function renderResultContent(content: ToolResultContent, isError?: boolean): h.JSX.Element {
  if (typeof content === "string") {
    return (
      <pre class={`tool-result ${isError ? "error" : ""}`}>
        {content}
      </pre>
    );
  }
  return (
    <div class={`tool-result-blocks ${isError ? "error" : ""}`}>
      {content.map((block, i) => {
        if (block.type === "text" && block.text) {
          return <Markdown key={i} text={block.text} class="text-content" />;
        }
        return <pre key={i}>{JSON.stringify(block, null, 2)}</pre>;
      })}
    </div>
  );
}

const defaultExpandedTools = new Set(["Edit", "Write", "Bash", "ExitPlanMode", "Task", "TodoWrite"]);
const defaultExpandedResults = new Set(["Bash", "Task"]);

export function ToolCall({ name, input, result, children }: Props) {
  const [inputOpen, setInputOpen] = useState(defaultExpandedTools.has(name));
  const [resultOpen, setResultOpen] = useState(defaultExpandedResults.has(name));
  const subtitle = getHeaderSubtitle(name, input);

  const filePath = typeof input.file_path === "string" ? input.file_path : null;
  const useReadHighlight = name === "Read" && filePath && result && !result.isError && typeof result.content === "string";

  return (
    <div class={`tool-call ${result?.isError ? "tool-error" : ""}`}>
      <div class="tool-header" onClick={() => setInputOpen(!inputOpen)}>
        <span class="tool-icon">{result ? (result.isError ? "!" : "\u2713") : "\u2026"}</span>
        <span class="tool-name">{name}</span>
        {subtitle}
        {!result && <span class="tool-spinner" />}
      </div>
      {inputOpen && formatInput(name, input)}
      {children}
      {result && (
        <div class="tool-result-section">
          <div
            class="tool-result-header"
            onClick={() => setResultOpen(!resultOpen)}
          >
            {resultOpen ? "\u25BC" : "\u25B6"} Result
          </div>
          {resultOpen && (
            useReadHighlight
              ? <ReadResult content={result.content as string} filePath={filePath!} />
              : renderResultContent(result.content, result.isError)
          )}
        </div>
      )}
    </div>
  );
}
