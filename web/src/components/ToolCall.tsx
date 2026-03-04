import { h, Fragment, ComponentChildren } from "preact";
import { useState } from "preact/hooks";
import { diffLines, diffWordsWithSpace, type Change } from "diff";
import type { ToolResult, ToolResultContent } from "../types";
import type { ThemedToken } from "../highlight";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { hasAnsi, renderAnsi } from "../ansi";
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

/** Split a diffLines change value into individual line strings. */
function splitChangeLines(value: string): string[] {
  const lines = value.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

interface AnnotatedSpan {
  content: string;
  color?: string;
  emphasized: boolean;
}

/**
 * Overlay word-level diff segments onto syntax highlighting tokens.
 * Both cover the same text split at different boundaries; we walk both
 * in parallel, splitting at whichever boundary comes first.
 */
function overlayDiff(
  syntaxTokens: ThemedToken[] | null,
  wordChanges: Change[],
  side: "old" | "new",
): AnnotatedSpan[] {
  const relevant = wordChanges.filter((c) =>
    side === "old" ? !c.added : !c.removed,
  );

  if (!syntaxTokens) {
    return relevant.map((c) => ({
      content: c.value,
      emphasized: side === "old" ? !!c.removed : !!c.added,
    }));
  }

  const result: AnnotatedSpan[] = [];
  let tIdx = 0;
  let tOff = 0;

  for (const change of relevant) {
    let remaining = change.value.length;
    const emphasized = side === "old" ? !!change.removed : !!change.added;

    while (remaining > 0 && tIdx < syntaxTokens.length) {
      const token = syntaxTokens[tIdx];
      const available = token.content.length - tOff;
      const take = Math.min(remaining, available);

      result.push({
        content: token.content.slice(tOff, tOff + take),
        color: token.color,
        emphasized,
      });

      remaining -= take;
      tOff += take;
      if (tOff >= token.content.length) {
        tIdx++;
        tOff = 0;
      }
    }
  }

  return result;
}

function renderAnnotatedSpans(
  spans: AnnotatedSpan[],
  side: "removed" | "added",
): h.JSX.Element {
  return (
    <Fragment>
      {spans.map((s, i) => (
        <span
          key={i}
          class={
            s.emphasized
              ? side === "removed"
                ? "diff-word-removed"
                : "diff-word-added"
              : undefined
          }
          style={s.color ? { color: s.color } : undefined}
        >
          {s.content}
        </span>
      ))}
    </Fragment>
  );
}

/** Dice coefficient: ratio of shared content between two sides of a word diff. */
function wordDiffSimilarity(wordChanges: Change[]): number {
  let commonLen = 0;
  let oldLen = 0;
  let newLen = 0;
  for (const c of wordChanges) {
    if (!c.added && !c.removed) {
      commonLen += c.value.length;
      oldLen += c.value.length;
      newLen += c.value.length;
    } else if (c.removed) {
      oldLen += c.value.length;
    } else {
      newLen += c.value.length;
    }
  }
  const total = oldLen + newLen;
  return total > 0 ? (2 * commonLen) / total : 1;
}

const WORD_DIFF_THRESHOLD = 0.4;

function DiffView({
  oldStr,
  newStr,
  filePath,
}: {
  oldStr: string;
  newStr: string;
  filePath?: string;
}) {
  const lang = filePath ? langFromPath(filePath) : null;
  const oldTokens = useHighlight(oldStr, lang);
  const newTokens = useHighlight(newStr, lang);

  const changes = diffLines(oldStr, newStr);

  const elements: h.JSX.Element[] = [];
  let oldLineIdx = 0;
  let newLineIdx = 0;

  for (let ci = 0; ci < changes.length; ci++) {
    const change = changes[ci];
    const lines = splitChangeLines(change.value);

    if (!change.added && !change.removed) {
      // Context
      for (let i = 0; i < lines.length; i++) {
        const idx = oldLineIdx++;
        newLineIdx++;
        elements.push(
          <div key={`c${idx}`} class="diff-context">
            {"  "}
            {oldTokens?.[idx] ? renderTokens(oldTokens[idx]) : lines[i]}
          </div>,
        );
      }
    } else if (change.removed) {
      const next = ci + 1 < changes.length ? changes[ci + 1] : null;

      if (next?.added) {
        // Adjacent removed+added block: compute word-level diffs for
        // positional pairs, but only apply emphasis when similarity is
        // above threshold. Always render removed-first, added-second.
        const addedLines = splitChangeLines(next.value);
        const pairCount = Math.min(lines.length, addedLines.length);

        // Pre-compute word diffs and similarity for each pair
        const wordDiffs: { changes: Change[]; similar: boolean }[] = [];
        for (let i = 0; i < pairCount; i++) {
          const wc = diffWordsWithSpace(lines[i], addedLines[i]);
          wordDiffs.push({
            changes: wc,
            similar: wordDiffSimilarity(wc) >= WORD_DIFF_THRESHOLD,
          });
        }

        // All removed lines (with word emphasis on similar pairs)
        for (let i = 0; i < lines.length; i++) {
          const idx = oldLineIdx + i;
          if (i < pairCount && wordDiffs[i].similar) {
            const spans = overlayDiff(
              oldTokens?.[idx] ?? null,
              wordDiffs[i].changes,
              "old",
            );
            elements.push(
              <div key={`r${idx}`} class="diff-removed">
                {"- "}
                {renderAnnotatedSpans(spans, "removed")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`r${idx}`} class="diff-removed">
                {"- "}
                {oldTokens?.[idx] ? renderTokens(oldTokens[idx]) : lines[i]}
              </div>,
            );
          }
        }

        // All added lines (with word emphasis on similar pairs)
        for (let i = 0; i < addedLines.length; i++) {
          const idx = newLineIdx + i;
          if (i < pairCount && wordDiffs[i].similar) {
            const spans = overlayDiff(
              newTokens?.[idx] ?? null,
              wordDiffs[i].changes,
              "new",
            );
            elements.push(
              <div key={`a${idx}`} class="diff-added">
                {"+ "}
                {renderAnnotatedSpans(spans, "added")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`a${idx}`} class="diff-added">
                {"+ "}
                {newTokens?.[idx]
                  ? renderTokens(newTokens[idx])
                  : addedLines[i]}
              </div>,
            );
          }
        }

        oldLineIdx += lines.length;
        newLineIdx += addedLines.length;
        ci++; // skip the paired added change
      } else {
        // Pure removed lines
        for (let i = 0; i < lines.length; i++) {
          const idx = oldLineIdx++;
          elements.push(
            <div key={`r${idx}`} class="diff-removed">
              {"- "}
              {oldTokens?.[idx] ? renderTokens(oldTokens[idx]) : lines[i]}
            </div>,
          );
        }
      }
    } else {
      // Pure added lines
      for (let i = 0; i < lines.length; i++) {
        const idx = newLineIdx++;
        elements.push(
          <div key={`a${idx}`} class="diff-added">
            {"+ "}
            {newTokens?.[idx] ? renderTokens(newTokens[idx]) : lines[i]}
          </div>,
        );
      }
    }
  }

  const oldLineCount = oldStr.split("\n").length;
  const newLineCount = newStr.split("\n").length;

  return (
    <div class="diff-view">
      <div class="diff-header">
        @@ -{oldLineCount} +{newLineCount} @@
      </div>
      {elements}
    </div>
  );
}

function EditInput({ input }: { input: Record<string, unknown> }) {
  const oldString = input.old_string as string;
  const newString = input.new_string as string;
  const filePath =
    typeof input.file_path === "string" ? input.file_path : undefined;
  const remaining = Object.entries(input).filter(
    ([k]) =>
      !["file_path", "old_string", "new_string", "replace_all"].includes(k),
  );

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      <DiffView oldStr={oldString} newStr={newString} filePath={filePath} />
    </div>
  );
}

function WriteInput({ input }: { input: Record<string, unknown> }) {
  const content = input.content as string;
  const filePath =
    typeof input.file_path === "string" ? input.file_path : undefined;
  const lang = filePath ? langFromPath(filePath) : null;
  const tokens = useHighlight(content, lang);
  const remaining = Object.entries(input).filter(
    ([k]) => !["file_path", "content"].includes(k),
  );

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      <pre class="write-content">
        {tokens ? renderTokenLines(tokens) : content}
      </pre>
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
    <pre class="write-content">
      {tokens ? renderTokenLines(tokens) : command}
    </pre>,
  );
}

function ReadResult({
  content,
  filePath,
}: {
  content: string;
  filePath: string;
}) {
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
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      <div class="todo-list">
        {todos.map((item, i) => (
          <div key={i} class={`todo-item todo-${item.status}`}>
            <span class="todo-status">
              {item.status === "completed"
                ? "\u2713"
                : item.status === "in_progress"
                  ? "\u25B6"
                  : "\u25CB"}
            </span>
            <span class="todo-content">{item.content}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

interface AskQuestion {
  question: string;
  header: string;
  options: Array<{ label: string; description: string }>;
  multiSelect?: boolean;
}

function AskUserQuestionInput({ input }: { input: Record<string, unknown> }) {
  const questions = input.questions as AskQuestion[];

  return (
    <div class="tool-input-formatted">
      {questions.map((q, qi) => (
        <div key={qi} class="ask-question">
          <div class="ask-question-header">{q.header}</div>
          <div class="ask-question-text">{q.question}</div>
          <div class="ask-options">
            {q.options.map((opt, oi) => (
              <div key={oi} class="ask-option">
                <div class="ask-option-label">{opt.label}</div>
                <Markdown text={opt.description} class="ask-option-desc" />
              </div>
            ))}
          </div>
          {q.multiSelect && (
            <div class="ask-multi-hint">Multiple selections allowed</div>
          )}
        </div>
      ))}
    </div>
  );
}

function formatGenericInput(
  input: Record<string, unknown>,
  children?: ComponentChildren,
): h.JSX.Element {
  const entries = Object.entries(input);
  return (
    <div class="tool-input-formatted">
      {entries.map(([k, v]) => {
        const str = typeof v === "string" ? v : JSON.stringify(v, null, 2);
        const isMultiline = str.includes("\n");
        return (
          <div key={k} class="tool-input-field">
            <span class="field-label">{k}:</span>
            {isMultiline ? (
              <pre class="field-value-block">{str}</pre>
            ) : (
              <span class="field-value"> {str}</span>
            )}
          </div>
        );
      })}
      {children}
    </div>
  );
}

function getHeaderSubtitle(
  name: string,
  input: Record<string, unknown>,
): h.JSX.Element | null {
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
    const range =
      offset != null && limit != null
        ? `(${offset}\u2013${offset + limit - 1})`
        : offset != null
          ? `(${offset}\u2013)`
          : limit != null
            ? `(1\u2013${limit})`
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
        {path && (
          <Fragment>
            {" in "}
            <code class="tool-subtitle-path">{path}</code>
          </Fragment>
        )}
      </Fragment>
    );
  }
  if (name === "AskUserQuestion" && Array.isArray(input.questions)) {
    const questions = input.questions as AskQuestion[];
    if (questions.length === 1) {
      return <span class="tool-subtitle">{questions[0].header}</span>;
    }
    return <span class="tool-subtitle">{questions.length} questions</span>;
  }
  if (name === "Bash" && typeof input.description === "string") {
    return <span class="tool-subtitle">{input.description}</span>;
  }
  if (name === "Task" && typeof input.description === "string") {
    const prefix =
      typeof input.subagent_type === "string" ? `${input.subagent_type}: ` : "";
    return (
      <span class="tool-subtitle">
        {prefix}
        {input.description}
      </span>
    );
  }
  return null;
}

function formatInput(
  name: string,
  input: Record<string, unknown>,
): h.JSX.Element {
  if (name === "Edit" && "old_string" in input && "new_string" in input) {
    return <EditInput input={input} />;
  }
  if (name === "Write" && "file_path" in input && "content" in input) {
    return <WriteInput input={input} />;
  }
  if (
    (name === "TodoWrite" || "todos" in input) &&
    Array.isArray(input.todos)
  ) {
    return formatTodoWriteInput(input);
  }
  if (name === "AskUserQuestion" && Array.isArray(input.questions)) {
    return <AskUserQuestionInput input={input} />;
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

function renderResultContent(
  content: ToolResultContent,
  isError?: boolean,
): h.JSX.Element {
  if (typeof content === "string") {
    return (
      <pre class={`tool-result ${isError ? "error" : ""}`}>
        {hasAnsi(content) ? renderAnsi(content) : content}
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

const defaultExpandedTools = new Set([
  "Edit",
  "Write",
  "Bash",
  "ExitPlanMode",
  "Task",
  "TodoWrite",
  "AskUserQuestion",
]);
const defaultExpandedResults = new Set(["Bash", "Task"]);

export function ToolCall({ name, input, result, children }: Props) {
  const [inputOpen, setInputOpen] = useState(defaultExpandedTools.has(name));
  const [resultOpen, setResultOpen] = useState(
    defaultExpandedResults.has(name),
  );
  const subtitle = getHeaderSubtitle(name, input);

  const filePath = typeof input.file_path === "string" ? input.file_path : null;
  const useReadHighlight =
    name === "Read" &&
    filePath &&
    result &&
    !result.isError &&
    typeof result.content === "string";

  return (
    <div class={`tool-call ${result?.isError ? "tool-error" : ""}`}>
      <div class="tool-header" onClick={() => setInputOpen(!inputOpen)}>
        <span class="tool-icon">
          {result ? (result.isError ? "!" : "\u2713") : "\u2026"}
        </span>
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
          {resultOpen &&
            (useReadHighlight ? (
              <ReadResult
                content={result.content as string}
                filePath={filePath!}
              />
            ) : (
              renderResultContent(result.content, result.isError)
            ))}
        </div>
      )}
    </div>
  );
}
