import { h, Fragment, ComponentChildren } from "preact";
import { memo } from "preact/compat";
import { useState, useMemo, useEffect } from "preact/hooks";
import { diffLines, diffWordsWithSpace, type Change } from "diff";
import HtmlDiff from "htmldiff-js";
import { marked } from "marked";
import type { ToolResult, ToolResultContent } from "../types";
import { sanitizeHtml } from "../sanitize";
import type { ThemedToken } from "../highlight";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { hasAnsi, renderAnsi } from "../ansi";
import { Markdown, sourceOnIcon, sourceOffIcon } from "./Markdown";
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

function toolKey(name: string, server?: string): string {
  return server ? `${server}:${name}` : name;
}

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
  const cls = `tool-result${isError ? " error" : ""}${
    className ? ` ${className}` : ""
  }`;
  return (
    <CodePre class={cls} copyText={content}>
      {children ?? (hasAnsi(content) ? renderAnsi(content) : content)}
    </CodePre>
  );
}

/** Extract plain text from tool result content, regardless of shape. */
function extractResultText(
  content: ToolResultContent | null | undefined,
): string | null {
  if (content == null) return null;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  const texts = content
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text!);
  return texts.length > 0 ? texts.join("") : null;
}

/** Tool names that represent shell command execution across agents/formats. */
const shellToolNames = new Set([
  "Bash", // Claude Code
  "bash", // Copilot
  "commandExecution", // Codex live
  "local_shell_call", // Codex rollout (OpenAI Responses API format)
  "exec_command", // Codex rollout (function_call format)
]);

/** Tool names that represent file write operations across agents/formats. */
const fileWriteToolNames = new Set([
  "Write", // Claude Code
  "fileChange", // Codex live
]);

/** Strip cat -n line number prefixes ("    1→" or "    1\t") from text. */
function stripCatLineNumbers(text: string): string {
  return text.replace(/^\s*\d+[\u2192\t]/gm, "");
}

/**
 * Check if text content looks like a valid SVG document.
 * Used for content-sniffing when no filePath is available.
 */
function looksLikeSvg(text: string): boolean {
  const trimmed = text.trim();
  const body = trimmed.startsWith("<?xml")
    ? trimmed.slice(trimmed.indexOf("?>") + 2).trim()
    : trimmed;
  if (!body.startsWith("<svg")) return false;
  if (!body.includes("</svg>")) return false;
  return true;
}

/** Detected renderable file format. */
type FileFormat = "markdown" | "svg" | null;

/** Detect renderable format from file path, or content-sniff if no path. */
function detectFormat(filePath?: string | null, content?: string): FileFormat {
  if (filePath) {
    const lang = langFromPath(filePath);
    if (lang === "markdown" || lang === "mdx") return "markdown";
    if (filePath.endsWith(".svg")) return "svg";
  }
  if (content && looksLikeSvg(stripCatLineNumbers(content).trim()))
    return "svg";
  return null;
}

/** Inline SVG rendered from raw SVG content string. */
function SvgPreview({ content }: { content: string }) {
  const dataUri = `data:image/svg+xml,${encodeURIComponent(content.trim())}`;
  return (
    <div class="tool-result-images">
      <img src={dataUri} alt="SVG preview" class="tool-result-image" />
    </div>
  );
}

/** Toggle wrapper for source/rendered views. */
function SourceRenderedToggle({
  defaultSource,
  sourceView,
  renderedView,
}: {
  defaultSource: boolean;
  sourceView: h.JSX.Element;
  renderedView: h.JSX.Element;
}) {
  const [showSource, setShowSource] = useState(defaultSource);
  return (
    <div class="markdown-diff-wrap">
      <button
        class="markdown-toggle-btn"
        onClick={() => {
          setShowSource(!showSource);
        }}
        title={showSource ? "Show rendered" : "Show source"}
      >
        <span
          class="action-icon"
          dangerouslySetInnerHTML={{
            __html: showSource ? sourceOnIcon : sourceOffIcon,
          }}
        />
      </button>
      {showSource ? sourceView : renderedView}
    </div>
  );
}

interface Props {
  name: string;
  toolServer?: string;
  toolSource?: string;
  toolUseId?: string;
  input: Record<string, unknown>;
  result?: ToolResult;
  streaming?: boolean;
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

function parsePatchTextFromInput(
  input: Record<string, unknown>,
): string | null {
  const direct = [input.input, input.patchText, input.patch, input.diff];
  for (const candidate of direct) {
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate;
    }
  }
  return null;
}

function parseApplyPatchPaths(patchText: string): string[] {
  const lines = patchText.split("\n");
  const paths: string[] = [];
  const seen = new Set<string>();
  const addPath = (path: string | null) => {
    if (!path || path === "/dev/null" || seen.has(path)) return;
    seen.add(path);
    paths.push(
      path.startsWith("a/") || path.startsWith("b/") ? path.slice(2) : path,
    );
  };

  let lastOld: string | null = null;
  for (const line of lines) {
    if (line.startsWith("*** Add File: ")) {
      addPath(line.slice("*** Add File: ".length).trim());
      continue;
    }
    if (line.startsWith("*** Update File: ")) {
      addPath(line.slice("*** Update File: ".length).trim());
      continue;
    }
    if (line.startsWith("*** Delete File: ")) {
      addPath(line.slice("*** Delete File: ".length).trim());
      continue;
    }
    if (line.startsWith("--- ")) {
      lastOld = line.slice(4).trim();
      continue;
    }
    if (line.startsWith("+++ ")) {
      const nextPath = line.slice(4).trim();
      if (nextPath === "/dev/null") addPath(lastOld);
      else addPath(nextPath);
    }
  }
  return paths;
}

function getToolCallFilePaths(
  name: string,
  input: Record<string, unknown>,
): string[] {
  const paths: string[] = [];
  const seen = new Set<string>();
  const addPath = (path: string | null) => {
    if (!path || seen.has(path)) return;
    seen.add(path);
    paths.push(path);
  };

  addPath(typeof input.file_path === "string" ? input.file_path : null);
  addPath(
    name === "view" && typeof input.path === "string" ? input.path : null,
  );

  if (name === "fileChange" && Array.isArray(input.changes)) {
    for (const change of input.changes) {
      if (!change || typeof change !== "object" || Array.isArray(change))
        continue;
      const c = change as Record<string, unknown>;
      addPath(
        typeof c.file_path === "string"
          ? c.file_path
          : typeof c.path === "string"
            ? c.path
            : null,
      );
    }
  }

  if (name === "apply_patch") {
    const patchText = parsePatchTextFromInput(input);
    if (patchText) {
      for (const path of parseApplyPatchPaths(patchText)) addPath(path);
    }
  }

  return paths;
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
  let rowKey = 0;
  let oldTokenIdx = 0;
  let newTokenIdx = 0;

  for (let hi = 0; hi < hunks.length; hi++) {
    const hunk = hunks[hi]!;
    const keyPrefix = `h${hi}`;
    elements.push(
      <div key={`${keyPrefix}-${rowKey++}`} class="diff-header">
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
          <div key={`${keyPrefix}-${rowKey++}`} class="diff-context">
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
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-removed">
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
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-removed">
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
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
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
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
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
          <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
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
  const diffHtml = useMemo(() => {
    const oldHtml = marked.parse(oldStr, { async: false });
    const newHtml = marked.parse(newStr, { async: false });
    return sanitizeHtml(HtmlDiff.execute(oldHtml, newHtml));
  }, [oldStr, newStr]);

  return (
    <SourceRenderedToggle
      defaultSource={true}
      sourceView={
        <DiffView oldStr={oldStr} newStr={newStr} filePath="diff.md" />
      }
      renderedView={
        <div
          class="markdown markdown-diff"
          dangerouslySetInnerHTML={{ __html: diffHtml }}
        />
      }
    />
  );
}

function SvgDiffView({
  oldStr,
  newStr,
  originalFile,
}: {
  oldStr: string;
  newStr: string;
  originalFile: string | null;
}) {
  const fullBefore = originalFile ?? oldStr;
  const fullAfter = useMemo(() => {
    if (!originalFile) return newStr;
    const idx = originalFile.indexOf(oldStr);
    if (idx < 0) return newStr;
    return (
      originalFile.slice(0, idx) +
      newStr +
      originalFile.slice(idx + oldStr.length)
    );
  }, [originalFile, oldStr, newStr]);

  return (
    <SourceRenderedToggle
      defaultSource={true}
      sourceView={
        <DiffView oldStr={oldStr} newStr={newStr} filePath="diff.svg" />
      }
      renderedView={
        <div class="svg-diff-preview">
          <div class="svg-diff-side">
            <div class="svg-diff-label">Before</div>
            <SvgPreview content={fullBefore} />
          </div>
          <div class="svg-diff-side">
            <div class="svg-diff-label">After</div>
            <SvgPreview content={fullAfter} />
          </div>
        </div>
      }
    />
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
  const format = detectFormat(filePath);
  const remaining = Object.entries(input).filter(
    ([k]) =>
      !["file_path", "old_string", "new_string", "replace_all"].includes(k),
  );
  const patchHunks = (result?.toolResult as Record<string, unknown> | undefined)
    ?.structuredPatch;
  const originalFile =
    typeof (result?.toolResult as Record<string, unknown> | undefined)
      ?.originalFile === "string"
      ? ((result!.toolResult as Record<string, unknown>).originalFile as string)
      : null;

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      {format === "markdown" ? (
        <MarkdownDiffView oldStr={oldString} newStr={newString} />
      ) : format === "svg" ? (
        <SvgDiffView
          oldStr={oldString}
          newStr={newString}
          originalFile={originalFile}
        />
      ) : Array.isArray(patchHunks) && patchHunks.length > 0 ? (
        <PatchView hunks={patchHunks as PatchHunk[]} filePath={filePath} />
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
  const format = detectFormat(filePath);
  const lang = filePath ? langFromPath(filePath) : null;
  const tokens = useHighlight(content, format === "markdown" ? null : lang);
  const remaining = Object.entries(input).filter(
    ([k]) => !["file_path", "content"].includes(k),
  );

  const codeView = (
    <CodePre class="write-content" copyText={content}>
      {tokens ? renderTokenLines(tokens) : content}
    </CodePre>
  );

  return (
    <div class="tool-input-formatted">
      {remaining.map(([k, v]) => (
        <div key={k} class="tool-input-field">
          <span class="field-label">{k}:</span>{" "}
          <span class="field-value">{String(v)}</span>
        </div>
      ))}
      {format === "svg" ? (
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={codeView}
          renderedView={<SvgPreview content={content} />}
        />
      ) : format === "markdown" ? (
        <Markdown text={content} class="write-content-markdown" />
      ) : (
        codeView
      )}
    </div>
  );
}

interface FileChangeRowData {
  path: string | null;
  operationLabel: string;
  mode: "diff" | "patch" | "content";
  oldStr?: string;
  newStr?: string;
  patchHunks?: PatchHunk[];
  content?: string;
}

function looksLikePatchText(text: string): boolean {
  const trimmed = text.trimStart();
  return (
    trimmed.startsWith("*** Begin Patch") ||
    trimmed.startsWith("@@") ||
    trimmed.startsWith("--- ") ||
    trimmed.startsWith("diff --git ") ||
    /\n@@/.test(text)
  );
}

export function parsePatchHunksFromText(text: string): PatchHunk[] | null {
  const lines = text.split("\n");
  const hunks: PatchHunk[] = [];
  let sawMalformedLine = false;
  let nextBareOldStart = 1;
  let nextBareNewStart = 1;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (!line.startsWith("@@")) continue;
    const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);

    const hunkLines: string[] = [];
    i++;
    while (i < lines.length) {
      const current = lines[i]!;
      if (current.startsWith("@@")) {
        i--;
        break;
      }
      if (
        current.startsWith("*** End Patch") ||
        current.startsWith("*** Update File: ") ||
        current.startsWith("*** Add File: ") ||
        current.startsWith("*** Delete File: ") ||
        current.startsWith("diff --git ") ||
        current.startsWith("--- ") ||
        current.startsWith("+++ ")
      ) {
        break;
      }
      if (current.startsWith("\\ No newline at end of file")) {
        i++;
        continue;
      }
      // Allow a terminal trailing newline after the final hunk body.
      if (current === "" && i === lines.length - 1) {
        break;
      }

      const prefix = current[0];
      if (prefix === " " || prefix === "+" || prefix === "-") {
        hunkLines.push(current);
        i++;
        continue;
      }
      sawMalformedLine = true;
      break;
    }

    if (sawMalformedLine) {
      return null;
    }
    if (!match && hunkLines.length === 0) {
      return null;
    }

    let oldStart: number;
    let oldLines = 0;
    let newStart: number;
    let newLines = 0;

    if (match) {
      oldStart = Number(match[1]);
      oldLines = match[2] != null ? Number(match[2]) : 1;
      newStart = Number(match[3]);
      newLines = match[4] != null ? Number(match[4]) : 1;
      nextBareOldStart = oldStart + Math.max(oldLines, 1);
      nextBareNewStart = newStart + Math.max(newLines, 1);
    } else {
      for (const hunkLine of hunkLines) {
        const prefix = hunkLine[0];
        if (prefix === " " || prefix === "-") oldLines++;
        if (prefix === " " || prefix === "+") newLines++;
      }
      oldStart = nextBareOldStart;
      newStart = nextBareNewStart;
      nextBareOldStart += Math.max(oldLines, 1);
      nextBareNewStart += Math.max(newLines, 1);
    }

    hunks.push({
      oldStart,
      oldLines,
      newStart,
      newLines,
      lines: hunkLines,
    });
  }

  return hunks.length > 0 ? hunks : null;
}

function parseFileChangeOperation(
  kind: unknown,
  op: unknown,
  diffText: string | null,
): {
  label: string;
  type: "add" | "update" | "delete" | "other";
} {
  const opType = typeof op === "string" ? op : null;
  const kindType =
    kind &&
    typeof kind === "object" &&
    !Array.isArray(kind) &&
    typeof (kind as Record<string, unknown>).type === "string"
      ? ((kind as Record<string, unknown>).type as string)
      : typeof kind === "string"
        ? kind
        : null;
  const normalized = (kindType ?? opType)?.trim().toLowerCase();

  if (normalized === "add" || normalized === "create" || normalized === "new") {
    return { label: "Add", type: "add" };
  }
  if (
    normalized === "update" ||
    normalized === "patch" ||
    normalized === "modify" ||
    normalized === "edit"
  ) {
    return { label: "Patch", type: "update" };
  }
  if (normalized === "delete" || normalized === "remove") {
    return { label: "Delete", type: "delete" };
  }

  if (diffText && looksLikePatchText(diffText)) {
    return { label: "Patch", type: "update" };
  }
  if (normalized && normalized.length > 0) {
    const label = normalized[0]!.toUpperCase() + normalized.slice(1);
    return { label, type: "other" };
  }
  return { label: "Change", type: "other" };
}

function parseFileChangeRows(input: Record<string, unknown>): {
  rows: FileChangeRowData[];
  unparsedChanges: unknown[];
} {
  if (!Array.isArray(input.changes)) return { rows: [], unparsedChanges: [] };
  const rows: FileChangeRowData[] = [];
  const unparsedChanges: unknown[] = [];

  for (const rawChange of input.changes) {
    if (
      !rawChange ||
      typeof rawChange !== "object" ||
      Array.isArray(rawChange)
    ) {
      unparsedChanges.push(rawChange);
      continue;
    }
    const change = rawChange as Record<string, unknown>;
    const path =
      typeof change.path === "string"
        ? change.path
        : typeof change.file_path === "string"
          ? change.file_path
          : null;
    const diffText = typeof change.diff === "string" ? change.diff : null;
    const patchText =
      typeof change.patchText === "string" ? change.patchText : null;
    const contentText =
      typeof change.content === "string" ? change.content : null;
    const oldString =
      typeof change.old_string === "string"
        ? change.old_string
        : typeof change.oldString === "string"
          ? change.oldString
          : null;
    const newString =
      typeof change.new_string === "string"
        ? change.new_string
        : typeof change.newString === "string"
          ? change.newString
          : null;
    const hasOperation =
      typeof change.op === "string" ||
      typeof change.kind === "string" ||
      (change.kind &&
        typeof change.kind === "object" &&
        !Array.isArray(change.kind) &&
        typeof (change.kind as Record<string, unknown>).type === "string");
    const hasBodyLike =
      typeof diffText === "string" ||
      typeof patchText === "string" ||
      typeof contentText === "string" ||
      typeof oldString === "string" ||
      typeof newString === "string";
    if (!path && !hasOperation && !hasBodyLike) {
      unparsedChanges.push(rawChange);
      continue;
    }
    const bodyText = diffText ?? patchText ?? contentText;
    const body = typeof bodyText === "string" ? bodyText : null;
    const operation = parseFileChangeOperation(
      change.kind,
      change.op,
      bodyText,
    );
    if (operation.type === "add") {
      const newStr = newString ?? contentText ?? diffText ?? patchText ?? "";
      rows.push({
        path,
        operationLabel: operation.label,
        mode: "diff",
        oldStr: "",
        newStr,
      });
      continue;
    }
    if (operation.type === "delete") {
      const oldStr = oldString ?? diffText ?? contentText ?? patchText ?? "";
      rows.push({
        path,
        operationLabel: operation.label,
        mode: "diff",
        oldStr,
        newStr: "",
      });
      continue;
    }

    if (typeof oldString === "string" && typeof newString === "string") {
      rows.push({
        path,
        operationLabel: operation.label,
        mode: "diff",
        oldStr: oldString,
        newStr: newString,
      });
      continue;
    }

    if (body && looksLikePatchText(body)) {
      const patchHunks = parsePatchHunksFromText(body);
      if (patchHunks) {
        rows.push({
          path,
          operationLabel: operation.label,
          mode: "patch",
          patchHunks,
        });
      } else {
        rows.push({
          path,
          operationLabel: operation.label,
          mode: "content",
          content: body,
        });
      }
      continue;
    }

    if (body) {
      rows.push({
        path,
        operationLabel: operation.label,
        mode: "content",
        content: body,
      });
      continue;
    }

    unparsedChanges.push(rawChange);
  }

  return { rows, unparsedChanges };
}

function FileChangeRow({
  row,
  showMeta,
}: {
  row: FileChangeRowData;
  showMeta: boolean;
}) {
  const lang = row.path ? langFromPath(row.path) : null;
  const contentText = row.content ?? "";
  const contentLang = looksLikePatchText(contentText) ? "diff" : lang;
  const contentTokens = useHighlight(contentText, contentLang);

  return (
    <div class="filechange-change">
      {showMeta && (
        <div class="tool-input-field filechange-meta">
          <span class="tool-subtitle-tag">{row.operationLabel}</span>
          <span class="tool-subtitle-path">{row.path ?? "(unknown file)"}</span>
        </div>
      )}
      {row.mode === "diff" && (
        <DiffView
          oldStr={row.oldStr ?? ""}
          newStr={row.newStr ?? ""}
          filePath={row.path ?? undefined}
        />
      )}
      {row.mode === "patch" && row.patchHunks && (
        <PatchView hunks={row.patchHunks} filePath={row.path ?? undefined} />
      )}
      {row.mode === "content" && row.content && (
        <CodePre class="write-content" copyText={row.content}>
          {contentTokens ? renderTokenLines(contentTokens) : row.content}
        </CodePre>
      )}
    </div>
  );
}

function getSingleFileChangeHeaderSubtitle(
  input: Record<string, unknown>,
): h.JSX.Element | null {
  const { rows, unparsedChanges } = parseFileChangeRows(input);
  if (rows.length !== 1 || unparsedChanges.length > 0) return null;

  const row = rows[0]!;
  if (!row.path) return null;

  return (
    <Fragment>
      <span class="tool-subtitle-tag">{row.operationLabel}</span>
      <span class="tool-subtitle-path">{row.path}</span>
    </Fragment>
  );
}

function FileChangeInput({ input }: { input: Record<string, unknown> }) {
  const { rows, unparsedChanges } = parseFileChangeRows(input);
  if (rows.length === 0) return formatGenericInput(input);
  const showRowMeta = rows.length > 1 || unparsedChanges.length > 0;

  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k !== "changes") remaining[k] = v;
  }
  if (unparsedChanges.length > 0) {
    remaining.changes = unparsedChanges;
  }
  return formatGenericInput(
    remaining,
    <div class="filechange-list">
      {rows.map((row, i) => (
        <FileChangeRow key={i} row={row} showMeta={showRowMeta} />
      ))}
    </div>,
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
  const format = detectFormat(filePath);
  const lang = langFromPath(filePath);

  const rawLines = content.split("\n");
  // Parse line-number prefixes:
  //   cat -n format: "    1→code" (→ = U+2192) or "    1\tcode"
  //   view format:   "1527. code"
  const parsed = rawLines.map((line) => {
    const match = line.match(/^(\s*\d+[\u2192\t]|\d+\.\s)(.*)/);
    if (match) return { prefix: match[1], code: match[2] };
    return { prefix: "", code: line };
  });

  const codeOnly = parsed.map((p) => p.code).join("\n");
  const tokens = useHighlight(codeOnly, lang);

  const sourceView = (
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

  const renderedMdHtml = useMemo(
    () =>
      format === "markdown"
        ? sanitizeHtml(marked.parse(codeOnly, { async: false }))
        : null,
    [codeOnly, format],
  );

  if (format === "markdown") {
    return (
      <SourceRenderedToggle
        defaultSource={false}
        sourceView={sourceView}
        renderedView={
          <div
            class="markdown"
            dangerouslySetInnerHTML={{ __html: renderedMdHtml! }}
          />
        }
      />
    );
  }

  if (format === "svg") {
    return (
      <SourceRenderedToggle
        defaultSource={false}
        sourceView={sourceView}
        renderedView={<SvgPreview content={codeOnly} />}
      />
    );
  }

  return sourceView;
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
  input: Record<string, unknown>,
  result?: ToolResult,
): Record<string, string> | null {
  // Built-in AskUserQuestion: answers in toolResult
  const tur = result?.toolResult as Record<string, unknown> | undefined;
  if (tur?.answers && typeof tur.answers === "object") {
    return tur.answers as Record<string, string>;
  }
  // MCP AskUserQuestion: parse from result text
  // Format: User has answered your questions: "Q"="A". "Q2"="A2".
  if (result) {
    const text = extractResultText(result.content);
    if (text == null) return null;
    const prefix = "User has answered your questions: ";
    if (text.startsWith(prefix)) {
      const answers: Record<string, string> = {};
      const body = text.slice(prefix.length);

      const questions = Array.isArray(input.questions) ? input.questions : null;
      if (questions) {
        for (const q of questions) {
          const question =
            q &&
            typeof q === "object" &&
            typeof (q as AskQuestion).question === "string"
              ? (q as AskQuestion).question
              : null;
          if (question == null) continue;
          const marker = `"${question}"="`;
          const start = body.indexOf(marker);
          if (start < 0) continue;
          const valueStart = start + marker.length;
          for (let i = valueStart; i < body.length; i++) {
            if (body[i] !== '"') continue;
            const next = body[i + 1];
            if (next === "." || next === undefined) {
              answers[question] = body.slice(valueStart, i);
              break;
            }
          }
        }
        if (Object.keys(answers).length > 0) return answers;
      }

      let cursor = 0;
      while (cursor < body.length) {
        const start = body.indexOf('"', cursor);
        if (start < 0) break;
        const keyValueSep = body.indexOf('"="', start + 1);
        if (keyValueSep < 0) break;

        const key = body.slice(start + 1, keyValueSep);
        const valueStart = keyValueSep + 3;
        let valueEnd = -1;
        for (let i = valueStart; i < body.length; i++) {
          if (body[i] !== '"') continue;
          const next = body[i + 1];
          if (next === "." || next === undefined) {
            valueEnd = i;
            break;
          }
        }
        if (valueEnd < 0) break;

        const value = body.slice(valueStart, valueEnd);
        answers[key] = value;

        cursor = valueEnd + 1;
        if (body[cursor] === ".") cursor++;
        if (body[cursor] === " ") cursor++;
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
                    class={`ask-option${
                      isSelected ? " ask-option-selected" : ""
                    }`}
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
    return (
      <CodePre class="tool-result" copyText={content}>
        {content}
      </CodePre>
    );
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

function parseCydoTaskResult(content: string): unknown[] | null {
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
        : // Single-object result (e.g. question from Ask)
          parsedObj != null
          ? [parsedObj]
          : null;
    return arr && arr.length > 0 ? arr : null;
  } catch {
    return null;
  }
}

function formatCydoTaskResultItem(item: Record<string, unknown>): {
  fields: Record<string, unknown>;
  text: string | null;
} {
  const text =
    typeof item.error === "string"
      ? item.error
      : typeof item.question === "string"
        ? item.question
        : typeof item.summary === "string"
          ? item.summary
          : typeof item.result === "string"
            ? item.result
            : null;
  const {
    error: _error,
    question: _question,
    summary,
    result: _result,
    ...rest
  } = item;
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
    "returnCodeInterpretation",
    "isImage",
    "noOutputExpected",
    "backgroundTaskId",
    "backgroundedByUser",
    "assistantAutoBackgrounded",
    "persistedOutputPath",
    "persistedOutputSize",
  ]),
  commandExecution: new Set([
    "exitCode",
    "status",
    "durationMs",
    "command",
    "cwd",
    "processId",
    "commandActions",
  ]),
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
  "cydo:AskUserQuestion": new Set(["questions", "answers"]),
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
    "agentType",
    "toolStats",
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
  "cydo:Task": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "title",
    "question",
  ]),
  "cydo:Ask": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "qid",
    "title",
    "question",
  ]),
  "cydo:Answer": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "qid",
    "title",
    "question",
  ]),
  "cydo:SwitchMode": new Set(["message"]),
  "cydo:Handoff": new Set(["message"]),
};

function formatToolUseResult(
  name: string,
  toolServer: string | undefined,
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
    return (
      <CodePre
        class="tool-result"
        copyText={JSON.stringify(toolResult, null, 2)}
      >
        {JSON.stringify(toolResult, null, 2)}
      </CodePre>
    );
  }

  if (Object.keys(toolResult).length === 0) return null;

  const known = knownResultFields[toolKey(name, toolServer)];
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
  toolServer: string | undefined,
  input: Record<string, unknown>,
): h.JSX.Element | null {
  const viewPaths = getToolCallFilePaths(name, input);
  const filePath = typeof input.file_path === "string" ? input.file_path : null;

  if (name === "Edit" && filePath) {
    return (
      <Fragment>
        <span class="tool-subtitle-path">{filePath}</span>
        {input.replace_all && <span class="tool-subtitle-tag">all</span>}
      </Fragment>
    );
  }
  if (fileWriteToolNames.has(name) && filePath) {
    return <span class="tool-subtitle-path">{filePath}</span>;
  }
  if (name === "fileChange") {
    const singleFileSubtitle = getSingleFileChangeHeaderSubtitle(input);
    if (singleFileSubtitle) return singleFileSubtitle;
    if (viewPaths.length > 1) {
      return <span class="tool-subtitle">{viewPaths.length} files</span>;
    }
  }
  if (name === "apply_patch") {
    if (viewPaths.length === 1) {
      return <span class="tool-subtitle-path">{viewPaths[0]}</span>;
    }
    if (viewPaths.length > 1) {
      return <span class="tool-subtitle">{viewPaths.length} files</span>;
    }
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
  if (name === "view" && typeof input.path === "string") {
    const vr = Array.isArray(input.view_range) ? input.view_range : null;
    const range =
      vr && vr.length === 2
        ? `(${vr[0]}\u2013${vr[1]})`
        : vr && vr.length === 1
          ? `(${vr[0]}\u2013)`
          : null;
    return (
      <Fragment>
        <span class="tool-subtitle-path">{input.path}</span>
        {range && <span class="tool-subtitle">{range}</span>}
      </Fragment>
    );
  }
  if (
    ["Glob", "Grep", "glob", "grep"].includes(name) &&
    typeof input.pattern === "string"
  ) {
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
  if (name === "AskUserQuestion" && Array.isArray(input.questions)) {
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
  if (shellToolNames.has(name) && typeof input.description === "string") {
    return <span class="tool-subtitle">{input.description}</span>;
  }
  if (name === "report_intent" && typeof input.intent === "string") {
    return <span class="tool-subtitle">{input.intent}</span>;
  }
  if (
    (name === "Task" || name === "task") &&
    typeof input.description === "string"
  ) {
    const agentType =
      typeof input.subagent_type === "string"
        ? input.subagent_type
        : typeof input.agent_type === "string"
          ? input.agent_type
          : null;
    return (
      <Fragment>
        {agentType && <span class="tool-subtitle-tag">{agentType}</span>}
        <span class="tool-subtitle">{input.description}</span>
      </Fragment>
    );
  }
  // --- CyDo MCP tools ---
  if (
    name === "SwitchMode" &&
    toolServer === "cydo" &&
    typeof input.continuation === "string"
  ) {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (
    name === "Handoff" &&
    toolServer === "cydo" &&
    typeof input.continuation === "string"
  ) {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (name === "Task" && toolServer === "cydo") {
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
  toolServer: string | undefined,
  input: Record<string, unknown>,
  result?: ToolResult,
): h.JSX.Element {
  if (name === "fileChange" && Array.isArray(input.changes)) {
    return <FileChangeInput input={input} />;
  }
  if (name === "Edit" && "old_string" in input && "new_string" in input) {
    return <EditInput input={input} result={result} />;
  }
  if (
    fileWriteToolNames.has(name) &&
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
  if (name === "AskUserQuestion" && Array.isArray(input.questions)) {
    return <AskUserQuestionInput input={input} result={result} />;
  }
  if (name === "ExitPlanMode" && typeof input.plan === "string") {
    const { plan, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={plan} />);
  }
  if (
    (name === "Task" || name === "task") &&
    typeof input.prompt === "string"
  ) {
    const {
      prompt,
      description,
      subagent_type,
      agent_type,
      name: taskName,
      mode,
      ...remaining
    } = input;
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
    shellToolNames.has(name) &&
    (typeof input.command === "string" || typeof input.cmd === "string")
  ) {
    return <ShellCommandInput input={input} />;
  }
  if (name === "Read" && typeof input.file_path === "string") {
    const { file_path, offset, limit, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (name === "view" && typeof input.path === "string") {
    const { path, view_range, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (
    ["Glob", "Grep", "glob", "grep"].includes(name) &&
    typeof input.pattern === "string"
  ) {
    const { pattern, glob, path, output_mode, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  // --- CyDo MCP tools ---
  if (
    (name === "Ask" || name === "Answer") &&
    toolServer === "cydo" &&
    typeof input.message === "string"
  ) {
    const { message, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={message} />);
  }
  if (name === "Task" && toolServer === "cydo" && Array.isArray(input.tasks)) {
    return formatTaskSpecsInput(input.tasks as Array<Record<string, unknown>>);
  }
  if (name === "Handoff" && toolServer === "cydo") {
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

/** Extract and render image blocks from tool result content. */
function renderResultImages(
  content: ToolResultContent | null | undefined,
): h.JSX.Element | null {
  if (!Array.isArray(content)) return null;
  const images: Array<{ data: string; mediaType: string }> = [];
  for (const block of content) {
    if (block.type !== "image") continue;
    const b = block as Record<string, unknown>;
    const src = b.source as Record<string, unknown> | undefined;
    if (
      src &&
      typeof src.data === "string" &&
      typeof src.media_type === "string"
    )
      images.push({ data: src.data, mediaType: src.media_type });
    else if (typeof b.data === "string" && typeof b.media_type === "string")
      images.push({
        data: b.data,
        mediaType: b.media_type,
      });
  }
  if (images.length === 0) return null;
  return (
    <div class="tool-result-images">
      {images.map((img, i) => (
        <img
          key={i}
          src={`data:${img.mediaType};base64,${img.data}`}
          alt="Tool result image"
          class="tool-result-image"
        />
      ))}
    </div>
  );
}

/**
 * Content-aware result renderer with source/rendered toggle.
 * Detects SVG via content sniffing and provides a rendered preview toggle.
 * Falls through to plain ResultPre for unrecognized content.
 */
function SmartResultPre({
  content,
  isError,
}: {
  content: string;
  isError?: boolean;
}) {
  const format = detectFormat(null, content);
  const tokens = useHighlight(content, format === "svg" ? "xml" : null);

  if (!format) {
    return (
      <ResultPre content={content} isError={isError}>
        {hasAnsi(content) ? renderAnsi(content) : content}
      </ResultPre>
    );
  }

  return (
    <SourceRenderedToggle
      defaultSource={true}
      sourceView={
        <ResultPre content={content} isError={isError}>
          {tokens ? renderTokenLines(tokens) : content}
        </ResultPre>
      }
      renderedView={
        <SvgPreview content={stripCatLineNumbers(content).trim()} />
      }
    />
  );
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
    const json =
      typeof content === "string" ? content : JSON.stringify(content, null, 2);
    return <ResultPre content={json} isError={isError} />;
  }
  // Standard path: extract text from content blocks, render as monospace
  const text = content
    .filter((block) => block.type === "text" && block.text)
    .map((block) => block.text!)
    .join("\n");

  // Pretty-print compact JSON strings
  let display = text;
  if (text.startsWith("{") || text.startsWith("[")) {
    try {
      display = JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      /* not JSON, use as-is */
    }
  }

  return <SmartResultPre content={display} isError={isError} />;
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
    output ? (
      <ResultPre content={output} class="field-value-block" />
    ) : undefined,
  );
}

/**
 * Render commandExecution result metadata: exit code (when non-zero) and duration.
 */
function formatCommandExecutionResult(
  toolResult: Record<string, unknown>,
): h.JSX.Element | null {
  const fields: Record<string, unknown> = {};
  if (typeof toolResult.exitCode === "number" && toolResult.exitCode !== 0)
    fields.exit_code = toolResult.exitCode;
  if (typeof toolResult.durationMs === "number")
    fields.duration_ms = `${toolResult.durationMs}ms`;
  if (Object.keys(fields).length === 0) return null;
  return formatGenericInput(fields);
}

/**
 * Render Bash result supplemental fields: stderr (when non-empty), interrupted (when true),
 * and returnCodeInterpretation (when present).
 */
function formatBashResult(
  toolResult: Record<string, unknown>,
): h.JSX.Element | null {
  const fields: Record<string, unknown> = {};
  if (typeof toolResult.stderr === "string" && toolResult.stderr.length > 0)
    fields.stderr = toolResult.stderr;
  if (toolResult.interrupted === true) fields.interrupted = true;
  if (
    typeof toolResult.returnCodeInterpretation === "string" &&
    toolResult.returnCodeInterpretation.length > 0
  )
    fields.returnCodeInterpretation = toolResult.returnCodeInterpretation;
  if (Object.keys(fields).length === 0) return null;
  return formatGenericInput(fields);
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
  "Task",
  "task",
  "Ask",
  "Answer",
  "Handoff",
  "SendMessage",
  "TaskCreate",
  "bash",
]);
const defaultExpandedResults = new Set([
  "Bash",
  "bash",
  "commandExecution",
  "local_shell_call",
  "exec_command",
  "Task",
  "task",
  "Ask",
  "Answer",
  "WebSearch",
  "WebFetch",
  "TaskOutput",
  "TaskStop",
]);

function hasReadOnlyCommandActions(result?: ToolResult): boolean {
  const toolResult =
    result?.toolResult != null && typeof result.toolResult === "object"
      ? (result.toolResult as Record<string, unknown>)
      : null;
  const commandActions = toolResult?.commandActions;
  return (
    Array.isArray(commandActions) &&
    commandActions.length > 0 &&
    commandActions.every(
      (action) =>
        action != null &&
        typeof action === "object" &&
        !Array.isArray(action) &&
        ((action as Record<string, unknown>).type === "read" ||
          (action as Record<string, unknown>).type === "listFiles" ||
          (action as Record<string, unknown>).type === "search"),
    )
  );
}

function defaultResultExpanded(name: string, result?: ToolResult): boolean {
  if (name === "commandExecution" && hasReadOnlyCommandActions(result))
    return false;
  return defaultExpandedResults.has(name);
}

const askToolNames = new Set(["AskUserQuestion"]);

export const ToolCall = memo(
  function ToolCall({
    name,
    toolServer,
    toolUseId,
    input,
    result,
    streaming,
    children,
    onViewFile,
  }: Props) {
    // Collapse pending AskUserQuestion input — the interactive form shows the same content
    const isAsk = askToolNames.has(name);
    const [inputOpen, setInputOpen] = useState(
      isAsk ? !!result : defaultExpandedTools.has(name),
    );
    // Auto-expand when result arrives for ask tools
    useEffect(() => {
      if (isAsk && result) setInputOpen(true);
    }, [isAsk, !!result]);
    const [resultOpenOverride, setResultOpenOverride] = useState<
      boolean | null
    >(null);
    const resultOpen =
      resultOpenOverride ?? defaultResultExpanded(name, result);
    const subtitle = getHeaderSubtitle(name, toolServer, input);
    const viewPaths = onViewFile ? getToolCallFilePaths(name, input) : [];

    const filePath =
      typeof input.file_path === "string"
        ? input.file_path
        : name === "view" && typeof input.path === "string"
          ? input.path
          : null;
    const resultText = result ? extractResultText(result.content) : null;
    const cydoTaskItems =
      (name === "Task" || name === "Ask" || name === "Answer") &&
      toolServer === "cydo" &&
      resultText != null &&
      !result!.isError
        ? parseCydoTaskResult(resultText)
        : null;
    const useReadHighlight =
      (name === "Read" || name === "view") &&
      filePath &&
      resultText != null &&
      !result!.isError;
    const useExecCommandResult =
      name === "exec_command" && resultText != null && !result!.isError;
    const useWebSearchResult =
      name === "WebSearch" && resultText != null && !result!.isError;
    const useWebFetchResult =
      name === "WebFetch" && resultText != null && !result!.isError;
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
    const useCommandExecutionResult =
      name === "commandExecution" &&
      result != null &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const useBashResult =
      name === "Bash" &&
      result != null &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const taskOutputElement = useTaskOutputResult
      ? formatTaskOutputResult(result.toolResult as Record<string, unknown>)
      : null;
    const taskStopElement = useTaskStopResult
      ? formatTaskStopResult(result.toolResult as Record<string, unknown>)
      : null;
    const commandExecutionElement = useCommandExecutionResult
      ? formatCommandExecutionResult(
          result.toolResult as Record<string, unknown>,
        )
      : null;
    const bashElement = useBashResult
      ? formatBashResult(result.toolResult as Record<string, unknown>)
      : null;
    const resultImagesElement =
      !useReadHighlight && result ? renderResultImages(result.content) : null;

    const hasResultContent =
      result != null &&
      (() => {
        if (resultText != null && resultText.length > 0) return true;
        if (
          result.toolResult != null &&
          typeof result.toolResult === "object"
        ) {
          if (
            Array.isArray(result.toolResult)
              ? result.toolResult.length > 0
              : Object.keys(result.toolResult).length > 0
          )
            return true;
        }
        if (typeof result.content === "string" && result.content.length > 0)
          return true;
        if (Array.isArray(result.content) && result.content.length > 0)
          return true;
        if (cydoTaskItems) return true;
        if (taskOutputElement) return true;
        if (taskStopElement) return true;
        if (commandExecutionElement) return true;
        if (bashElement) return true;
        return false;
      })();

    return (
      <div
        id={toolUseId ? `tool-${toolUseId}` : undefined}
        class={`tool-call${streaming ? " streaming" : ""}${result?.isError ? " tool-error" : ""}`}
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
          {toolServer === "cydo" && (
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
          <span class="tool-name">{name}</span>
          {subtitle}
          {!result && <span class="tool-spinner" />}
          {(name === "Edit" ||
            name === "apply_patch" ||
            fileWriteToolNames.has(name)) &&
            viewPaths.length > 0 &&
            onViewFile && (
              <button
                class="tool-view-file"
                onClick={(e) => {
                  e.stopPropagation();
                  onViewFile(viewPaths[0]!);
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
        {inputOpen &&
          name !== "fileChange" &&
          viewPaths.length > 1 &&
          onViewFile && (
            <div class="tool-input-formatted">
              {viewPaths.map((path) => (
                <div key={path} class="tool-input-field">
                  <span class="field-label">file:</span>
                  <button
                    class="tool-subtitle-path"
                    onClick={(e) => {
                      e.stopPropagation();
                      onViewFile(path);
                    }}
                    type="button"
                  >
                    {path}
                  </button>
                </div>
              ))}
            </div>
          )}
        {inputOpen && formatInput(name, toolServer, input, result)}
        {children}
        {result && hasResultContent && (
          <div class="tool-result-section">
            <div
              class="tool-result-header"
              onClick={() => {
                setResultOpenOverride(!resultOpen);
              }}
            >
              {resultOpen ? "\u25BC" : "\u25B6"} Result
            </div>
            {resultOpen && (
              <>
                <div class="tool-result-container">
                  {!useReadHighlight && resultImagesElement}
                  {cydoTaskItems ? (
                    <div class="tool-input-formatted">
                      {cydoTaskItems.map((item, i) => {
                        if (
                          typeof item !== "object" ||
                          item === null ||
                          Array.isArray(item)
                        ) {
                          const fallbackText =
                            typeof item === "string" ? item : String(item);
                          return (
                            <div key={i} class="cydo-task-spec">
                              <div class="tool-input-field">
                                <span class="field-label">result:</span>
                                <span class="field-value"> {fallbackText}</span>
                              </div>
                            </div>
                          );
                        }
                        const { fields, text } = formatCydoTaskResultItem(
                          item as Record<string, unknown>,
                        );
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
                                <span class="tool-subtitle-tag">
                                  {taskType}
                                </span>
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
                            {text && (
                              <Markdown text={text} class="text-content" />
                            )}
                          </div>
                        );
                      })}
                    </div>
                  ) : useExecCommandResult ? (
                    <ExecCommandResult content={resultText} />
                  ) : useReadHighlight ? (
                    <ReadResult content={resultText} filePath={filePath} />
                  ) : useWebSearchResult ? (
                    <WebSearchResult content={resultText} />
                  ) : useWebFetchResult ? (
                    <div class="tool-result-blocks">
                      <Markdown text={resultText} class="text-content" />
                    </div>
                  ) : taskOutputElement ? (
                    taskOutputElement
                  ) : taskStopElement ? (
                    taskStopElement
                  ) : useBashResult ? (
                    (result.toolResult as Record<string, unknown>).stdout ? (
                      <SmartResultPre
                        content={
                          (result.toolResult as Record<string, unknown>)
                            .stdout as string
                        }
                        isError={result.isError}
                      />
                    ) : null
                  ) : resultImagesElement ? null : (
                    renderResultContent(result.content, result.isError)
                  )}
                </div>
                {commandExecutionElement}
                {bashElement}
                {result.toolResult != null &&
                  typeof result.toolResult === "object" &&
                  formatToolUseResult(
                    name,
                    toolServer,
                    result.toolResult as Record<string, unknown> | unknown[],
                  )}
              </>
            )}
          </div>
        )}
      </div>
    );
  },
  (prev, next) =>
    prev.name === next.name &&
    prev.toolServer === next.toolServer &&
    prev.toolSource === next.toolSource &&
    prev.toolUseId === next.toolUseId &&
    prev.input === next.input &&
    prev.result === next.result &&
    prev.streaming === next.streaming &&
    prev.children === next.children &&
    prev.onViewFile === next.onViewFile,
);
