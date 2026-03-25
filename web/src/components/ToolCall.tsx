import { h, Fragment, ComponentChildren } from "preact";
import { useState, useMemo, useEffect } from "preact/hooks";
import { diffLines, diffWordsWithSpace, type Change } from "diff";
import HtmlDiff from "htmldiff-js";
import { marked } from "marked";
import type { ToolResult, ToolResultContent } from "../types";
import { sanitizeHtml } from "../sanitize";
import type { ThemedToken } from "../highlight";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { hasAnsi, renderAnsi } from "../ansi";
import { Markdown } from "./Markdown";
import { CodePre } from "./CopyButton";

/**
 * Tool Result Rendering Principles
 *
 * 1. Best-effort rendering. If the structured toolResult is missing or not the
 *    shape we expect, fall through to the generic raw renderer. Never show an
 *    empty box when raw data is available.
 *
 * 2. Never discard unknown information. Always let formatToolUseResult() run —
 *    it surfaces unexpected fields as warnings. Custom renderers consume known
 *    fields visually; the knownResultFields mechanism handles the rest.
 *
 * 3. Progressive enhancement. Extract and display recognized fields with nice
 *    formatting (badges, labels, pre blocks). Unrecognized fields render in the
 *    generic key-value style. The two layers compose — custom renderer plus
 *    formatToolUseResult together cover everything.
 *
 * 4. Hide-if-expected, collapse-if-rarely-useful. Fields that always have the
 *    same observed value can be hidden when they match. Fields that are rarely
 *    useful go in a collapsed section. Routinely informative fields display
 *    prominently.
 */

const CYDO_PREFIX = "mcp__cydo__";

function ResultPre({
  content,
  class: className,
  isError,
  children,
}: {
  content: string;
  class?: string;
  isError?: boolean;
  children?: ComponentChildren;
}) {
  const cls = `tool-result${isError ? " error" : ""}${className ? ` ${className}` : ""}`;
  return (
    <CodePre class={cls} copyText={content}>
      {children ?? (hasAnsi(content) ? renderAnsi(content) : content)}
    </CodePre>
  );
}

/** Extract plain text from tool result content, regardless of shape. */
function extractResultText(content: ToolResultContent | null | undefined): string | null {
  if (content == null) return null;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  const texts = content.filter(b => b.type === "text" && b.text).map(b => b.text!);
  return texts.length > 0 ? texts.join("") : null;
}

/** Tool names that represent shell command execution across agents/formats. */
const shellToolNames = new Set([
  "Bash", // Claude Code
  "commandExecution", // Codex live
  "local_shell_call", // Codex rollout (OpenAI Responses API format)
  "exec_command", // Codex rollout (function_call format)
]);

/** Tool names that represent file write operations across agents/formats. */
const fileWriteToolNames = new Set([
  "Write", // Claude Code
  "fileChange", // Codex live
]);

function getDisplayName(name: string): string {
  return name.startsWith(CYDO_PREFIX) ? name.slice(CYDO_PREFIX.length) : name;
}

/** Check if a tool name (possibly mcp__cydo__ prefixed) matches a set. */
function toolNameIn(name: string, set: Set<string>): boolean {
  return set.has(name) || set.has(getDisplayName(name));
}

interface Props {
  name: string;
  toolUseId?: string;
  input: Record<string, unknown>;
  result?: ToolResult;
  children?: ComponentChildren;
  onViewFile?: (filePath: string) => void;
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
      emphasized: side === "old" ? c.removed : c.added,
    }));
  }

  const result: AnnotatedSpan[] = [];
  let tIdx = 0;
  let tOff = 0;

  for (const change of relevant) {
    let remaining = change.value.length;
    const emphasized = side === "old" ? change.removed : change.added;

    while (remaining > 0 && tIdx < syntaxTokens.length) {
      const token = syntaxTokens[tIdx]!;
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

export function DiffView({
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
    const change = changes[ci]!;
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
          const wc = diffWordsWithSpace(lines[i]!, addedLines[i]!);
          wordDiffs.push({
            changes: wc,
            similar: wordDiffSimilarity(wc) >= WORD_DIFF_THRESHOLD,
          });
        }

        // All removed lines (with word emphasis on similar pairs)
        for (let i = 0; i < lines.length; i++) {
          const idx = oldLineIdx + i;
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              oldTokens?.[idx] ?? null,
              wordDiffs[i]!.changes,
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
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              newTokens?.[idx] ?? null,
              wordDiffs[i]!.changes,
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

export interface PatchHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];
}

export function PatchView({
  hunks,
  filePath,
}: {
  hunks: PatchHunk[];
  filePath?: string;
}) {
  const lang = filePath ? langFromPath(filePath) : null;

  // Compute gutter width from max line number across all hunks
  let maxLineNum = 0;
  for (const hunk of hunks) {
    maxLineNum = Math.max(
      maxLineNum,
      hunk.oldStart + hunk.oldLines,
      hunk.newStart + hunk.newLines,
    );
  }
  const gutterWidth = `${String(maxLineNum).length}ch`;

  // Build old/new text for syntax highlighting
  const oldLinesList: string[] = [];
  const newLinesList: string[] = [];
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      const prefix = line[0];
      const content = line.slice(1);
      if (prefix === " " || prefix === "-") oldLinesList.push(content);
      if (prefix === " " || prefix === "+") newLinesList.push(content);
    }
  }

  const oldText = oldLinesList.join("\n");
  const newText = newLinesList.join("\n");
  const oldTokens = useHighlight(oldText, lang);
  const newTokens = useHighlight(newText, lang);

  const elements: h.JSX.Element[] = [];
  let oldTokenIdx = 0;
  let newTokenIdx = 0;

  for (const hunk of hunks) {
    elements.push(
      <div key={`h${hunk.oldStart}`} class="diff-header">
        @@ -{hunk.oldStart},{hunk.oldLines} +{hunk.newStart},{hunk.newLines} @@
      </div>,
    );

    let oldLineNum = hunk.oldStart;
    let newLineNum = hunk.newStart;
    const lines = hunk.lines;
    let li = 0;

    while (li < lines.length) {
      const prefix = lines[li]![0];
      if (prefix === " ") {
        const content = lines[li]!.slice(1);
        const oldIdx = oldTokenIdx++;
        newTokenIdx++;
        const oNum = oldLineNum++;
        const nNum = newLineNum++;
        elements.push(
          <div key={`c${oNum}`} class="diff-context">
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {oNum}
            </span>
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {nNum}
            </span>
            {"  "}
            {oldTokens?.[oldIdx] ? renderTokens(oldTokens[oldIdx]) : content}
          </div>,
        );
        li++;
      } else if (prefix === "-") {
        // Collect consecutive removed lines
        const removeStart = li;
        while (li < lines.length && lines[li]![0] === "-") li++;
        const removedContents = lines
          .slice(removeStart, li)
          .map((l) => l.slice(1));

        // Collect adjacent added lines
        const addStart = li;
        while (li < lines.length && lines[li]![0] === "+") li++;
        const addedContents = lines.slice(addStart, li).map((l) => l.slice(1));

        const pairCount = Math.min(
          removedContents.length,
          addedContents.length,
        );
        const wordDiffs: { changes: Change[]; similar: boolean }[] = [];
        for (let p = 0; p < pairCount; p++) {
          const wc = diffWordsWithSpace(removedContents[p]!, addedContents[p]!);
          wordDiffs.push({
            changes: wc,
            similar: wordDiffSimilarity(wc) >= WORD_DIFF_THRESHOLD,
          });
        }

        for (let p = 0; p < removedContents.length; p++) {
          const oldIdx = oldTokenIdx++;
          const oNum = oldLineNum++;
          if (p < pairCount && wordDiffs[p]!.similar) {
            const spans = overlayDiff(
              oldTokens?.[oldIdx] ?? null,
              wordDiffs[p]!.changes,
              "old",
            );
            elements.push(
              <div key={`r${oNum}`} class="diff-removed">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {oNum}
                </span>
                <span
                  class="diff-gutter"
                  style={{ minWidth: gutterWidth }}
                ></span>
                {"- "}
                {renderAnnotatedSpans(spans, "removed")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`r${oNum}`} class="diff-removed">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {oNum}
                </span>
                <span
                  class="diff-gutter"
                  style={{ minWidth: gutterWidth }}
                ></span>
                {"- "}
                {oldTokens?.[oldIdx]
                  ? renderTokens(oldTokens[oldIdx])
                  : removedContents[p]}
              </div>,
            );
          }
        }

        for (let p = 0; p < addedContents.length; p++) {
          const newIdx = newTokenIdx++;
          const nNum = newLineNum++;
          if (p < pairCount && wordDiffs[p]!.similar) {
            const spans = overlayDiff(
              newTokens?.[newIdx] ?? null,
              wordDiffs[p]!.changes,
              "new",
            );
            elements.push(
              <div key={`a${nNum}`} class="diff-added">
                <span
                  class="diff-gutter"
                  style={{ minWidth: gutterWidth }}
                ></span>
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {nNum}
                </span>
                {"+ "}
                {renderAnnotatedSpans(spans, "added")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`a${nNum}`} class="diff-added">
                <span
                  class="diff-gutter"
                  style={{ minWidth: gutterWidth }}
                ></span>
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {nNum}
                </span>
                {"+ "}
                {newTokens?.[newIdx]
                  ? renderTokens(newTokens[newIdx])
                  : addedContents[p]}
              </div>,
            );
          }
        }
      } else if (prefix === "+") {
        // Pure added line (no preceding removed block)
        const content = lines[li]!.slice(1);
        const newIdx = newTokenIdx++;
        const nNum = newLineNum++;
        elements.push(
          <div key={`a${nNum}`} class="diff-added">
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}></span>
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {nNum}
            </span>
            {"+ "}
            {newTokens?.[newIdx] ? renderTokens(newTokens[newIdx]) : content}
          </div>,
        );
        li++;
      } else {
        li++;
      }
    }
  }

  return <div class="diff-view">{elements}</div>;
}

function MarkdownDiffView({
  oldStr,
  newStr,
}: {
  oldStr: string;
  newStr: string;
}) {
  const [showSource, setShowSource] = useState(true);
  const diffHtml = useMemo(() => {
    const oldHtml = marked.parse(oldStr, { async: false });
    const newHtml = marked.parse(newStr, { async: false });
    return sanitizeHtml(HtmlDiff.execute(oldHtml, newHtml));
  }, [oldStr, newStr]);

  return (
    <div class="markdown-diff-wrap">
      <button
        class="markdown-toggle-btn"
        onClick={() => {
          setShowSource(!showSource);
        }}
        title={showSource ? "Show rendered" : "Show source"}
      >
        {showSource ? "\u25C9" : "\u25CE"}
      </button>
      {showSource ? (
        <DiffView oldStr={oldStr} newStr={newStr} filePath="diff.md" />
      ) : (
        <div
          class="markdown markdown-diff"
          dangerouslySetInnerHTML={{ __html: diffHtml }}
        />
      )}
    </div>
  );
}

function EditInput({
  input,
  result,
}: {
  input: Record<string, unknown>;
  result?: ToolResult;
}) {
  const oldString = input.old_string as string;
  const newString = input.new_string as string;
  const filePath =
    typeof input.file_path === "string" ? input.file_path : undefined;
  const lang = filePath ? langFromPath(filePath) : null;
  const isMarkdown = lang === "markdown" || lang === "mdx";
  const remaining = Object.entries(input).filter(
    ([k]) =>
      !["file_path", "old_string", "new_string", "replace_all"].includes(k),
  );
  const patchHunks = (result?.toolResult as Record<string, unknown> | undefined)
    ?.structuredPatch;

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      {Array.isArray(patchHunks) && patchHunks.length > 0 ? (
        <PatchView hunks={patchHunks as PatchHunk[]} filePath={filePath} />
      ) : isMarkdown ? (
        <MarkdownDiffView oldStr={oldString} newStr={newString} />
      ) : (
        <DiffView oldStr={oldString} newStr={newString} filePath={filePath} />
      )}
    </div>
  );
}

function WriteInput({ input }: { input: Record<string, unknown> }) {
  const content = input.content as string;
  const filePath =
    typeof input.file_path === "string" ? input.file_path : undefined;
  const lang = filePath ? langFromPath(filePath) : null;
  const isMarkdown = lang === "markdown" || lang === "mdx";
  const tokens = useHighlight(content, isMarkdown ? null : lang);
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
      {isMarkdown ? (
        <Markdown text={content} class="write-content-markdown" />
      ) : (
        <CodePre class="write-content" copyText={content}>
          {tokens ? renderTokenLines(tokens) : content}
        </CodePre>
      )}
    </div>
  );
}

function ShellCommandInput({ input }: { input: Record<string, unknown> }) {
  // Different Codex formats use different field names for the command:
  //   Bash/commandExecution/local_shell_call: "command"
  //   exec_command: "cmd"
  const command =
    typeof input.command === "string"
      ? input.command
      : typeof input.cmd === "string"
        ? input.cmd
        : null;
  const tokens = useHighlight(command ?? "", "bash");
  const consumedKeys = new Set(["command", "cmd", "description"]);
  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (!consumedKeys.has(k)) remaining[k] = v;
  }

  return formatGenericInput(
    remaining,
    command ? (
      <CodePre class="write-content" copyText={command}>
        {tokens ? renderTokenLines(tokens) : command}
      </CodePre>
    ) : undefined,
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
    <CodePre class="tool-result" copyText={codeOnly}>
      {parsed.map((p, i) => (
        <Fragment key={i}>
          {i > 0 && "\n"}
          {p.prefix && <span class="line-number">{p.prefix}</span>}
          {tokens?.[i] ? renderTokens(tokens[i]) : p.code}
        </Fragment>
      ))}
    </CodePre>
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

function formatTaskSpecsInput(
  tasks: Array<Record<string, unknown>>,
): h.JSX.Element {
  return (
    <div class="tool-input-formatted">
      {tasks.map((task, i) => {
        const taskType =
          typeof task.task_type === "string" ? task.task_type : null;
        const description =
          typeof task.description === "string" ? task.description : null;
        const prompt = typeof task.prompt === "string" ? task.prompt : null;
        return (
          <div key={i} class="cydo-task-spec">
            <div class="tool-input-field">
              {taskType && <span class="tool-subtitle-tag">{taskType}</span>}
              {description && <span class="field-value"> {description}</span>}
            </div>
            {prompt && <Markdown text={prompt} />}
          </div>
        );
      })}
    </div>
  );
}

interface AskQuestion {
  question: string;
  header: string;
  options: Array<{ label: string; description: string }>;
  multiSelect?: boolean;
}

function getAskAnswers(
  _input: Record<string, unknown>,
  result?: ToolResult,
): Record<string, string> | null {
  // Built-in AskUserQuestion: answers in toolResult
  const tur = result?.toolResult as Record<string, unknown> | undefined;
  if (tur?.answers && typeof tur.answers === "object") {
    return tur.answers as Record<string, string>;
  }
  // MCP AskUserQuestion: parse from result text
  // Format: User has answered your questions: "Q"="A". "Q2"="A2".
  if (result && typeof result.content === "string") {
    const prefix = "User has answered your questions: ";
    const text = result.content;
    if (text.startsWith(prefix)) {
      const answers: Record<string, string> = {};
      const body = text.slice(prefix.length);
      const re = /"([^"]*)"="([^"]*)"/g;
      let m;
      while ((m = re.exec(body)) !== null) {
        answers[m[1]!] = m[2]!;
      }
      if (Object.keys(answers).length > 0) return answers;
    }
  }
  return null;
}

function AskUserQuestionInput({
  input,
  result,
}: {
  input: Record<string, unknown>;
  result?: ToolResult;
}) {
  const questions = input.questions as AskQuestion[];
  const answers = getAskAnswers(input, result);

  return (
    <div class="tool-input-formatted">
      {questions.map((q, qi) => {
        const answer = answers?.[q.question];
        return (
          <div key={qi} class="ask-question">
            <div class="ask-question-header">{q.header}</div>
            <div class="ask-question-text">{q.question}</div>
            <div class="ask-options">
              {q.options.map((opt, oi) => {
                const isSelected =
                  answer != null &&
                  answer.split(", ").some((a) => a === opt.label);
                return (
                  <div
                    key={oi}
                    class={`ask-option${isSelected ? " ask-option-selected" : ""}`}
                  >
                    <div class="ask-option-label">{opt.label}</div>
                    <Markdown text={opt.description} class="ask-option-desc" />
                  </div>
                );
              })}
            </div>
            {answer != null && (
              <div class="ask-answer">
                <span class="ask-answer-label">Answer:</span> {answer}
              </div>
            )}
            {!answer && q.multiSelect && (
              <div class="ask-multi-hint">Multiple selections allowed</div>
            )}
          </div>
        );
      })}
    </div>
  );
}

interface WebSearchLink {
  title: string;
  url: string;
}

interface WebSearchIteration {
  query?: string;
  links: WebSearchLink[];
  body: string;
}

function parseWebSearchResult(content: string): WebSearchIteration[] | null {
  const lines = content.split("\n");

  // Strip trailing REMINDER line
  let end = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i]!.startsWith("REMINDER:")) {
      end = i;
      if (end > 0 && lines[end - 1]!.trim() === "") end--;
      break;
    }
  }

  const iterations: WebSearchIteration[] = [];
  let current: WebSearchIteration | null = null;
  const bodyLines: string[] = [];

  const flushBody = () => {
    if (!current) return;
    // Strip leading/trailing blank lines
    let s = 0,
      e = bodyLines.length;
    while (s < e && bodyLines[s]!.trim() === "") s++;
    while (e > s && bodyLines[e - 1]!.trim() === "") e--;
    current.body = bodyLines.slice(s, e).join("\n");
    bodyLines.length = 0;
  };

  for (let i = 0; i < end; i++) {
    const line = lines[i]!;
    if (line.startsWith("Web search results for query:")) {
      flushBody();
      if (current) iterations.push(current);
      const m = line.match(/^Web search results for query:\s*"(.+)"$/);
      current = { query: m ? m[1] : undefined, links: [], body: "" };
    } else if (line.startsWith("Links: ")) {
      // A bare Links: line also starts a new iteration if there's no current
      if (!current) {
        flushBody();
        current = { links: [], body: "" };
      } else if (current.links.length > 0) {
        // Another Links: block — start a new iteration
        flushBody();
        iterations.push(current);
        current = { links: [], body: "" };
      }
      try {
        const parsed: unknown = JSON.parse(line.slice(7));
        if (Array.isArray(parsed)) {
          current.links = parsed.filter(
            (l: unknown): l is WebSearchLink =>
              typeof l === "object" &&
              l !== null &&
              typeof (l as WebSearchLink).title === "string" &&
              typeof (l as WebSearchLink).url === "string",
          );
        }
      } catch {
        // invalid JSON, skip
      }
    } else {
      if (current) bodyLines.push(line);
    }
  }

  flushBody();
  if (current) iterations.push(current);

  if (iterations.length === 0) return null;
  return iterations;
}

function WebSearchResult({ content }: { content: string }) {
  const iterations = parseWebSearchResult(content);
  if (!iterations) {
    return <CodePre class="tool-result" copyText={content}>{content}</CodePre>;
  }

  return (
    <div class="tool-result-blocks">
      {iterations.map((iter, i) => (
        <div class="web-search-iteration" key={i}>
          {iter.query && <div class="web-search-query">"{iter.query}"</div>}
          {iter.links.length > 0 && (
            <div class="web-search-links">
              {iter.links.map((link, j) => (
                <a
                  key={j}
                  class="web-search-link"
                  href={link.url}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  {link.title}
                </a>
              ))}
            </div>
          )}
          {iter.body && <Markdown text={iter.body} class="text-content" />}
        </div>
      ))}
    </div>
  );
}

function parseCydoTaskResult(
  content: string,
): Record<string, unknown>[] | null {
  try {
    const parsed = JSON.parse(content) as unknown;
    // Backend returns either a raw array or {"tasks": [...]} wrapper
    const parsedObj =
      !Array.isArray(parsed) && typeof parsed === "object" && parsed !== null
        ? (parsed as Record<string, unknown>)
        : null;
    const arr: unknown[] | null = Array.isArray(parsed)
      ? parsed
      : Array.isArray(parsedObj?.tasks)
        ? parsedObj.tasks
        : null;
    return arr && arr.length > 0 ? (arr as Record<string, unknown>[]) : null;
  } catch {
    return null;
  }
}

function formatCydoTaskResultItem(item: Record<string, unknown>): {
  fields: Record<string, unknown>;
  text: string | null;
} {
  const text =
    typeof item.summary === "string"
      ? item.summary
      : typeof item.result === "string"
        ? item.result
        : null;
  const { summary, result: _result, ...rest } = item;
  return { fields: rest, text };
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

// Map tool name → set of known (ignored + consumed) toolResult field names.
const knownResultFields: Record<string, Set<string>> = {
  Bash: new Set([
    "stdout",
    "stderr",
    "interrupted",
    "isImage",
    "returnCodeInterpretation",
    "noOutputExpected",
    "backgroundTaskId",
    "backgroundedByUser",
    "persistedOutputPath",
    "persistedOutputSize",
  ]),
  commandExecution: new Set([]),
  local_shell_call: new Set([]),
  exec_command: new Set([]),
  Read: new Set(["type", "file"]),
  Edit: new Set([
    "filePath",
    "oldString",
    "newString",
    "replaceAll",
    "originalFile",
    "structuredPatch",
    "userModified",
  ]),
  Write: new Set([
    "type",
    "filePath",
    "content",
    "originalFile",
    "structuredPatch",
  ]),
  fileChange: new Set([]),
  Glob: new Set(["filenames", "numFiles", "truncated", "durationMs"]),
  Grep: new Set([
    "mode",
    "filenames",
    "numFiles",
    "content",
    "numLines",
    "numMatches",
    "appliedLimit",
    "appliedOffset",
  ]),
  TodoWrite: new Set(["oldTodos", "newTodos"]),
  WebSearch: new Set(["query", "results", "durationSeconds"]),
  WebFetch: new Set([
    "url",
    "code",
    "codeText",
    "result",
    "bytes",
    "durationMs",
  ]),
  AskUserQuestion: new Set(["questions", "answers", "annotations"]),
  mcp__cydo__AskUserQuestion: new Set(["questions", "answers"]),
  Task: new Set([
    "status",
    "prompt",
    "agentId",
    "content",
    "totalDurationMs",
    "totalTokens",
    "totalToolUseCount",
    "usage",
    "isAsync",
    "description",
    "outputFile",
    "canReadOutputFile",
    "teammate_id",
    "agent_id",
    "agent_type",
    "model",
    "name",
    "color",
    "team_name",
    "plan_mode_required",
    "is_splitpane",
    "tmux_pane_id",
    "tmux_session_name",
    "tmux_window_name",
  ]),
  TaskCreate: new Set(["task"]),
  TaskGet: new Set(["task"]),
  TaskList: new Set(["tasks"]),
  TaskOutput: new Set(["retrieval_status", "task"]),
  TaskStop: new Set(["message", "task_id", "task_type", "command"]),
  TaskUpdate: new Set([
    "success",
    "taskId",
    "updatedFields",
    "statusChange",
    "error",
  ]),
  TeamCreate: new Set(["team_name", "team_file_path", "lead_agent_id"]),
  TeamDelete: new Set(["success", "message", "team_name"]),
  SendMessage: new Set([
    "success",
    "message",
    "request_id",
    "target",
    "routing",
  ]),
  Skill: new Set(["success", "commandName", "allowedTools"]),
  EnterPlanMode: new Set(["message"]),
  ExitPlanMode: new Set(["plan", "filePath", "isAgent", "hasTaskTool"]),
  NotebookEdit: new Set([]),
  mcp__cydo__Task: new Set(["tasks", "content", "structuredContent"]),
  mcp__cydo__SwitchMode: new Set(["message"]),
  mcp__cydo__Handoff: new Set(["message"]),
};

function formatToolUseResult(
  name: string,
  toolResult: Record<string, unknown> | unknown[],
): h.JSX.Element | null {
  if (Array.isArray(toolResult)) {
    if (toolResult.length === 0) return null;
    // Skip structured content blocks — already rendered by renderResultContent
    if (
      toolResult.every(
        (b) => typeof b === "object" && b !== null && "type" in b,
      )
    )
      return null;
    return <CodePre class="tool-result" copyText={JSON.stringify(toolResult, null, 2)}>{JSON.stringify(toolResult, null, 2)}</CodePre>;
  }

  if (Object.keys(toolResult).length === 0) return null;

  const known = knownResultFields[name];
  const unknown: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(toolResult)) {
    if (!known?.has(k)) unknown[k] = v;
  }

  const consumed: h.JSX.Element | null = null;

  if (Object.keys(unknown).length === 0) return null;

  return (
    <>
      {consumed}
      {Object.keys(unknown).length > 0 && (
        <div class="unknown-result-fields">{formatGenericInput(unknown)}</div>
      )}
    </>
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
  if (toolNameIn(name, fileWriteToolNames) && filePath) {
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
    const glob = typeof input.glob === "string" ? input.glob : null;
    const path = typeof input.path === "string" ? input.path : null;
    return (
      <Fragment>
        <code class="tool-subtitle-pattern">{input.pattern}</code>
        {glob && (
          <Fragment>
            {" in "}
            <code class="tool-subtitle-pattern">{glob}</code>
          </Fragment>
        )}
        {path && (
          <Fragment>
            {" in "}
            <code class="tool-subtitle-path">{path}</code>
          </Fragment>
        )}
      </Fragment>
    );
  }
  if (
    (name === "AskUserQuestion" || name === "mcp__cydo__AskUserQuestion") &&
    Array.isArray(input.questions)
  ) {
    const questions = input.questions as AskQuestion[];
    if (questions.length === 1) {
      return <span class="tool-subtitle">{questions[0]!.header}</span>;
    }
    return <span class="tool-subtitle">{questions.length} questions</span>;
  }
  if (name === "WebSearch" && typeof input.query === "string") {
    return <span class="tool-subtitle">{input.query}</span>;
  }
  if (name === "WebFetch" && typeof input.url === "string") {
    return (
      <a
        class="tool-subtitle"
        href={input.url}
        target="_blank"
        rel="noopener noreferrer"
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        {input.url}
      </a>
    );
  }
  if (toolNameIn(name, shellToolNames) && typeof input.description === "string") {
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
  // --- CyDo MCP tools ---
  if (
    name === "mcp__cydo__SwitchMode" &&
    typeof input.continuation === "string"
  ) {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (name === "mcp__cydo__Handoff" && typeof input.continuation === "string") {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (name === "mcp__cydo__Task") {
    const tasks = input.tasks as
      | Array<{ task_type?: string; description?: string }>
      | undefined;
    if (Array.isArray(tasks)) {
      if (tasks.length === 1 && tasks[0]!.description) {
        return <span class="tool-subtitle">{tasks[0]!.description}</span>;
      }
      return <span class="tool-subtitle">{tasks.length} tasks</span>;
    }
  }
  // --- Claude Code built-in tools ---
  if (name === "SendMessage") {
    const type = typeof input.type === "string" ? input.type : null;
    const recipient =
      typeof input.recipient === "string" ? input.recipient : null;
    if (type && recipient) {
      return (
        <span class="tool-subtitle">
          {type} → {recipient}
        </span>
      );
    }
    if (type) {
      return <span class="tool-subtitle">{type}</span>;
    }
  }
  if (name === "TaskCreate") {
    const tasks = input.tasks as Array<{ description?: string }> | undefined;
    if (Array.isArray(tasks)) {
      if (tasks.length === 1 && tasks[0]!.description) {
        return <span class="tool-subtitle">{tasks[0]!.description}</span>;
      }
      return <span class="tool-subtitle">{tasks.length} tasks</span>;
    }
  }
  if (name === "TaskUpdate") {
    const rawId = input.task_id ?? input.taskId;
    const idStr =
      typeof rawId === "string" || typeof rawId === "number"
        ? String(rawId)
        : null;
    const status = typeof input.status === "string" ? input.status : null;
    if (idStr !== null && status) {
      return (
        <span class="tool-subtitle">
          #{idStr} → {status}
        </span>
      );
    }
  }
  if (name === "TaskOutput") {
    const taskId = typeof input.task_id === "string" ? input.task_id : null;
    if (taskId) {
      const timeout = typeof input.timeout === "number" ? input.timeout : null;
      const timeoutStr =
        timeout != null
          ? timeout >= 1000
            ? `${timeout / 1000}s`
            : `${timeout}ms`
          : null;
      return (
        <Fragment>
          <span class="tool-subtitle">{taskId}</span>
          {input.block === false && (
            <span class="tool-subtitle-tag">non-blocking</span>
          )}
          {timeoutStr && <span class="tool-subtitle-tag">{timeoutStr}</span>}
        </Fragment>
      );
    }
  }
  if (name === "TaskStop") {
    const taskId =
      typeof input.task_id === "string"
        ? input.task_id
        : typeof input.shell_id === "string"
          ? input.shell_id
          : null;
    if (taskId) {
      return <span class="tool-subtitle">{taskId}</span>;
    }
  }
  if (name === "Skill" && typeof input.skill === "string") {
    return <span class="tool-subtitle">{input.skill}</span>;
  }
  if (name === "TeamCreate" && typeof input.team_name === "string") {
    return <span class="tool-subtitle">{input.team_name}</span>;
  }
  if (name === "EnterWorktree") {
    const wName = typeof input.name === "string" ? input.name : null;
    if (wName) {
      return <span class="tool-subtitle">{wName}</span>;
    }
  }
  return null;
}

function formatInput(
  name: string,
  input: Record<string, unknown>,
  result?: ToolResult,
): h.JSX.Element {
  if (name === "Edit" && "old_string" in input && "new_string" in input) {
    return <EditInput input={input} result={result} />;
  }
  if (
    toolNameIn(name, fileWriteToolNames) &&
    "file_path" in input &&
    "content" in input
  ) {
    return <WriteInput input={input} />;
  }
  if (
    (name === "TodoWrite" || "todos" in input) &&
    Array.isArray(input.todos)
  ) {
    return formatTodoWriteInput(input);
  }
  if (
    (name === "AskUserQuestion" || name === "mcp__cydo__AskUserQuestion") &&
    Array.isArray(input.questions)
  ) {
    return <AskUserQuestionInput input={input} result={result} />;
  }
  if (name === "ExitPlanMode" && typeof input.plan === "string") {
    const { plan, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={plan} />);
  }
  if (name === "Task" && typeof input.prompt === "string") {
    const { prompt, description, subagent_type, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={prompt} />);
  }
  if (name === "WebSearch" && typeof input.query === "string") {
    const { query, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (name === "WebFetch" && typeof input.url === "string") {
    const { url, prompt, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof prompt === "string" ? <Markdown text={prompt} /> : undefined,
    );
  }
  if (
    toolNameIn(name, shellToolNames) &&
    (typeof input.command === "string" || typeof input.cmd === "string")
  ) {
    return <ShellCommandInput input={input} />;
  }
  if (name === "Read" && typeof input.file_path === "string") {
    const { file_path, offset, limit, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (["Glob", "Grep"].includes(name) && typeof input.pattern === "string") {
    const { pattern, glob, path, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  // --- CyDo MCP tools ---
  if (name === "mcp__cydo__Task" && Array.isArray(input.tasks)) {
    return formatTaskSpecsInput(input.tasks as Array<Record<string, unknown>>);
  }
  if (name === "mcp__cydo__Handoff") {
    const { continuation, prompt: handoffPrompt, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof handoffPrompt === "string" ? (
        <Markdown text={handoffPrompt} />
      ) : undefined,
    );
  }
  // --- Claude Code built-in tools ---
  if (name === "SendMessage") {
    const { type, recipient, summary, ...remaining } = input;
    const content = typeof input.content === "string" ? input.content : null;
    const filteredRemaining = Object.fromEntries(
      Object.entries(remaining).filter(([k]) => k !== "content"),
    );
    return formatGenericInput(
      filteredRemaining,
      content ? <Markdown text={content} /> : undefined,
    );
  }
  if (name === "Skill") {
    const { skill, args: skillArgs, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof skillArgs === "string" ? (
        <pre class="write-content">{skillArgs}</pre>
      ) : undefined,
    );
  }
  if (name === "TaskCreate" && Array.isArray(input.tasks)) {
    return formatTaskSpecsInput(input.tasks as Array<Record<string, unknown>>);
  }
  if (name === "TaskUpdate") {
    const { task_id, taskId, status, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (name === "TaskOutput") {
    const { task_id, block, timeout, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (name === "TaskStop") {
    const { task_id, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  return formatGenericInput(input);
}

/**
 * Parse Codex exec_command output format: key-value metadata lines followed
 * by "Output:\n" and the actual command output. Returns just the output
 * portion, or the original string if the marker is not found.
 */
function parseExecCommandOutput(text: string): string {
  const outputMarker = text.indexOf("Output:\n");
  if (outputMarker === -1) return text;
  return text.slice(outputMarker + "Output:\n".length);
}

function ExecCommandResult({ content }: { content: string }) {
  const output = parseExecCommandOutput(content);
  return <ResultPre content={output} />;
}

function renderResultContent(
  content: ToolResultContent | null | undefined,
  isError?: boolean,
): h.JSX.Element {
  if (content == null) {
    return <pre class={`tool-result ${isError ? "error" : ""}`}>{""}</pre>;
  }
  if (!Array.isArray(content)) {
    // Unexpected shape (string or object) — render defensively
    const json = typeof content === "string" ? content : JSON.stringify(content, null, 2);
    return <ResultPre content={json} isError={isError} />;
  }
  // Standard path: extract text from content blocks, render as monospace
  const text = content
    .filter(block => block.type === "text" && block.text)
    .map(block => block.text!)
    .join("\n");

  // Pretty-print compact JSON strings
  let display = text;
  if (text.startsWith("{") || text.startsWith("[")) {
    try {
      display = JSON.stringify(JSON.parse(text), null, 2);
    } catch { /* not JSON, use as-is */ }
  }

  return <ResultPre content={display} isError={isError} />;
}

/**
 * Render TaskOutput result using the same label: value pattern as
 * formatGenericInput. Flattens the nested `task` object into top-level
 * fields so they display like any other tool result.
 */
function formatTaskOutputResult(
  toolResult: Record<string, unknown>,
): h.JSX.Element | null {
  const retrievalStatus =
    typeof toolResult.retrieval_status === "string"
      ? toolResult.retrieval_status
      : null;
  const task =
    toolResult.task != null && typeof toolResult.task === "object"
      ? (toolResult.task as Record<string, unknown>)
      : null;

  // Principle 1: fall back to raw rendering if nothing meaningful to show
  if (!retrievalStatus && !task) return null;

  // Flatten: pull task fields to top level, skip task_id (already in subtitle)
  const fields: Record<string, unknown> = {};
  if (task) {
    if (typeof task.task_type === "string") fields.task_type = task.task_type;
    if (typeof task.status === "string") fields.status = task.status;
    // Principle 4: hide retrieval_status when "complete" (expected value)
    if (retrievalStatus && retrievalStatus !== "complete")
      fields.retrieval = retrievalStatus;
    if (typeof task.description === "string")
      fields.description = task.description;
    if (typeof task.exitCode === "number") fields.exit_code = task.exitCode;
  } else if (retrievalStatus) {
    fields.retrieval = retrievalStatus;
  }

  const output =
    task && typeof task.output === "string" && task.output.trim()
      ? task.output
      : null;

  return formatGenericInput(
    fields,
    output ? <pre class="field-value-block">{output}</pre> : undefined,
  );
}

/**
 * Render TaskStop result: show task_type and command using standard field layout.
 */
function formatTaskStopResult(
  toolResult: Record<string, unknown>,
): h.JSX.Element | null {
  const fields: Record<string, unknown> = {};
  if (typeof toolResult.task_type === "string")
    fields.task_type = toolResult.task_type;
  if (typeof toolResult.message === "string")
    fields.message = toolResult.message;
  if (typeof toolResult.command === "string")
    fields.command = toolResult.command;

  // Principle 1: fall back to raw rendering if nothing meaningful to show
  if (Object.keys(fields).length === 0) return null;

  return formatGenericInput(fields);
}

const defaultExpandedTools = new Set([
  "Edit",
  "Write",
  "fileChange",
  "Bash",
  "commandExecution",
  "local_shell_call",
  "exec_command",
  "ExitPlanMode",
  "TodoWrite",
  "AskUserQuestion",
  "WebFetch",
  "mcp__cydo__Task",
  "mcp__cydo__Handoff",
  "mcp__cydo__AskUserQuestion",
  "SendMessage",
  "TaskCreate",
]);
const defaultExpandedResults = new Set([
  "Bash",
  "commandExecution",
  "local_shell_call",
  "exec_command",
  "Task",
  "WebSearch",
  "WebFetch",
  "mcp__cydo__Task",
  "TaskOutput",
  "TaskStop",
]);

const askToolNames = new Set(["AskUserQuestion", "mcp__cydo__AskUserQuestion"]);

export function ToolCall({
  name,
  toolUseId,
  input,
  result,
  children,
  onViewFile,
}: Props) {
  // Collapse pending AskUserQuestion input — the interactive form shows the same content
  const isAsk = askToolNames.has(name);
  const [inputOpen, setInputOpen] = useState(
    isAsk ? !!result : toolNameIn(name, defaultExpandedTools),
  );
  // Auto-expand when result arrives for ask tools
  useEffect(() => {
    if (isAsk && result) setInputOpen(true);
  }, [isAsk, !!result]);
  const [resultOpen, setResultOpen] = useState(
    toolNameIn(name, defaultExpandedResults),
  );
  const subtitle = getHeaderSubtitle(name, input);

  const filePath = typeof input.file_path === "string" ? input.file_path : null;
  const resultText = result ? extractResultText(result.content) : null;
  const cydoTaskItems =
    name === "mcp__cydo__Task" && resultText != null && !result!.isError
      ? parseCydoTaskResult(resultText)
      : null;
  const useReadHighlight =
    name === "Read" &&
    filePath &&
    resultText != null &&
    !result!.isError;
  const useExecCommandResult =
    name === "exec_command" &&
    resultText != null &&
    !result!.isError;
  const useWebSearchResult =
    name === "WebSearch" &&
    resultText != null &&
    !result!.isError;
  const useWebFetchResult =
    name === "WebFetch" &&
    resultText != null &&
    !result!.isError;
  const useTaskOutputResult =
    name === "TaskOutput" &&
    result &&
    !result.isError &&
    result.toolResult != null &&
    typeof result.toolResult === "object";
  const useTaskStopResult =
    name === "TaskStop" &&
    result &&
    !result.isError &&
    result.toolResult != null &&
    typeof result.toolResult === "object";
  const taskOutputElement = useTaskOutputResult
    ? formatTaskOutputResult(result.toolResult as Record<string, unknown>)
    : null;
  const taskStopElement = useTaskStopResult
    ? formatTaskStopResult(result.toolResult as Record<string, unknown>)
    : null;

  return (
    <div
      id={toolUseId ? `tool-${toolUseId}` : undefined}
      class={`tool-call ${result?.isError ? "tool-error" : ""}`}
    >
      <div
        class="tool-header"
        onClick={() => {
          setInputOpen(!inputOpen);
        }}
      >
        <span class="tool-icon">
          {result ? (result.isError ? "!" : "\u2713") : "\u2026"}
        </span>
        {name.startsWith(CYDO_PREFIX) && (
          <svg
            class="cydo-tool-logo"
            width="13"
            height="13"
            viewBox="0 0 16 16"
            fill="none"
            stroke-width="2"
            stroke-linecap="round"
          >
            <path
              style={{ stroke: "var(--success)" }}
              d="M5.5 12L10.5 4L13 8l-2.5 4"
            />
            <path
              style={{ stroke: "var(--processing)" }}
              d="M5.5 4L3 8l2.5 4"
            />
          </svg>
        )}
        <span class="tool-name">{getDisplayName(name)}</span>
        {subtitle}
        {!result && <span class="tool-spinner" />}
        {(name === "Edit" || toolNameIn(name, fileWriteToolNames)) &&
          filePath &&
          onViewFile && (
            <button
              class="tool-view-file"
              onClick={(e) => {
                e.stopPropagation();
                onViewFile(filePath);
              }}
              title="View file"
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
                <circle cx="12" cy="12" r="3" />
              </svg>
            </button>
          )}
      </div>
      {inputOpen && formatInput(name, input, result)}
      {children}
      {result && (
        <div class="tool-result-section">
          <div
            class="tool-result-header"
            onClick={() => {
              setResultOpen(!resultOpen);
            }}
          >
            {resultOpen ? "\u25BC" : "\u25B6"} Result
          </div>
          {resultOpen && (
            <>
              {cydoTaskItems ? (
                <div class="tool-input-formatted">
                  {cydoTaskItems.map((item, i) => {
                    const { fields, text } = formatCydoTaskResultItem(item);
                    const taskType =
                      typeof fields.task_type === "string"
                        ? fields.task_type
                        : null;
                    const desc =
                      typeof fields.description === "string"
                        ? fields.description
                        : null;
                    const { task_type, description, ...rest } = fields;
                    return (
                      <div key={i} class="cydo-task-spec">
                        <div class="tool-input-field">
                          {taskType && (
                            <span class="tool-subtitle-tag">{taskType}</span>
                          )}
                          {desc && <span class="field-value"> {desc}</span>}
                        </div>
                        {Object.keys(rest).length > 0 &&
                          Object.entries(rest).map(([k, v]) => (
                            <div key={k} class="tool-input-field">
                              <span class="field-label">{k}:</span>
                              <span class="field-value"> {String(v)}</span>
                            </div>
                          ))}
                        {text && <Markdown text={text} class="text-content" />}
                      </div>
                    );
                  })}
                </div>
              ) : useExecCommandResult ? (
                <ExecCommandResult content={resultText} />
              ) : useReadHighlight ? (
                <ReadResult
                  content={resultText}
                  filePath={filePath}
                />
              ) : useWebSearchResult ? (
                <WebSearchResult content={resultText} />
              ) : useWebFetchResult ? (
                <div class="tool-result-blocks">
                  <Markdown
                    text={resultText}
                    class="text-content"
                  />
                </div>
              ) : taskOutputElement ? (
                taskOutputElement
              ) : taskStopElement ? (
                taskStopElement
              ) : (
                renderResultContent(result.content, result.isError)
              )}
              {result.toolResult != null &&
                typeof result.toolResult === "object" &&
                formatToolUseResult(
                  name,
                  result.toolResult as Record<string, unknown> | unknown[],
                )}
            </>
          )}
        </div>
      )}
    </div>
  );
}
