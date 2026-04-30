import { h, Fragment, ComponentChildren } from "preact";
import { memo } from "preact/compat";
import { useState, useMemo, useEffect, useRef } from "preact/hooks";
import { marked } from "marked";
import type { ToolResult, ToolResultContent } from "../types";
import { qualifiedToolKey, toolIs } from "../toolIdentity";
import { sanitizeHtml } from "../sanitize";
import { useHighlight, langFromPath, renderTokens } from "../highlight";
import { hasAnsi, renderAnsi } from "../ansi";
import { Markdown } from "./Markdown";
import { CodePre, CopyButton } from "./CopyButton";
import checkIcon from "../icons/check.svg?raw";
import errorIcon from "../icons/error.svg?raw";
import { DiffView, PatchView } from "./diff/DiffView";
import {
  FileContentPreview,
  SvgPreview,
} from "./file-preview/FileContentPreview";
import { MarkdownDiffPreview } from "./file-preview/MarkdownDiffPreview";
import { SvgDiffPreview } from "./file-preview/SvgDiffPreview";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";
import { SourceNodeView } from "./SourceNodeView";
import {
  SemanticShellOutput,
  hasSemanticShellOutput,
} from "./SemanticShellOutput";
import {
  detectRenderableFormat,
  isMarkdownPath,
  isSvgPath,
  looksLikeSvg,
  stripCatLineNumbers,
} from "../lib/fileFormats";
import {
  getApplyPatchFileChanges,
  getNormalizedFilePaths,
  parseCodexFileChanges,
  type NormalizedFileChange,
} from "../lib/fileChanges";
import {
  looksLikePatchText,
  parsePatchHunksFromText,
  parsePatchTextFromInput,
  parseApplyPatchSections,
  type PatchHunk,
} from "../lib/patches";
import {
  useShellSemantic,
  type ShellInputSegment,
  type ShellHeredocWriteSemantic,
  type ShellScriptExecSemantic,
} from "../lib/shellSemantic";
import { parseCommandSourceTree, type SourceNode } from "../lib/sourceTree";

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

/** Check if tool is a shell command executor across agents. */
const isShellTool = (
  name: string,
  agentType?: string,
  toolServer?: string,
): boolean =>
  toolIs(
    name,
    agentType,
    toolServer,
    "claude/Bash",
    "copilot/bash",
    "codex/commandExecution",
    "codex/local_shell_call",
    "codex/exec_command",
    "cydo:Bash",
  );

/** Check if tool is a file write operation across agents. */
const isFileWriteTool = (name: string, agentType?: string): boolean =>
  toolIs(name, agentType, undefined, "claude/Write", "codex/fileChange");

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

function extractShellInputCommand(
  input: Record<string, unknown>,
): string | null {
  if (typeof input.command === "string") return input.command;
  if (typeof input.cmd === "string") return input.cmd;
  return null;
}

function extractShellActionCommand(result?: ToolResult): string | null {
  const toolResult =
    result?.toolResult != null && typeof result.toolResult === "object"
      ? (result.toolResult as Record<string, unknown>)
      : null;
  const actions = toolResult?.commandActions;
  if (!Array.isArray(actions)) return null;
  for (const action of actions) {
    if (!action || typeof action !== "object" || Array.isArray(action))
      continue;
    const cmd = (action as Record<string, unknown>).command;
    if (typeof cmd === "string" && cmd.trim().length > 0) return cmd;
  }
  return null;
}

function extractSemanticShellCommand(
  input: Record<string, unknown>,
  result?: ToolResult,
): string | null {
  const base = extractShellInputCommand(input);
  const actionCommand = extractShellActionCommand(result);
  if (!actionCommand) return base;
  if (!base) return actionCommand;
  const actionLooksLikeShellWrapper =
    /^\s*(?:\S+\/)?(?:ba|z)?sh\s+-[cl]+\s+/i.test(actionCommand);
  // Codex commandExecution often reports an outer `sh -c "..."` wrapper
  // in input.command while commandActions[*].command can hold a normalized
  // semantic command. For multiline wrappers, keep the wrapper payload intact
  // so structured command-list parsing (e.g. sed/printf sections) can see all
  // commands, not just the first parsed action.
  if (/^\s*(?:\S+\/)?sh\s+-c\s+/i.test(base)) {
    // Nested shell wrappers (e.g. sh -c "/run/.../zsh -lc 'python <<PY'")
    // parse more reliably from commandActions than from heavily escaped input.
    if (actionLooksLikeShellWrapper) return actionCommand;
    if (base.includes("\n")) return base;
    return actionCommand;
  }
  return base;
}

interface Props {
  name: string;
  toolServer?: string;
  toolSource?: string;
  agentType?: string;
  toolUseId?: string;
  input: Record<string, unknown>;
  result?: ToolResult;
  streaming?: boolean;
  children?: ComponentChildren;
  onViewFile?: (filePath: string) => void;
}

/** Render an array of token lines (no trailing newline). */
function renderTokenLines(
  tokens: ReturnType<typeof useHighlight>,
): h.JSX.Element {
  if (!tokens) return <></>;
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

function getToolCallFilePaths(
  name: string,
  agentType: string | undefined,
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
    toolIs(name, agentType, undefined, "copilot/view") &&
      typeof input.path === "string"
      ? input.path
      : null,
  );

  if (toolIs(name, agentType, undefined, "codex/fileChange")) {
    const parsed = parseCodexFileChanges(input);
    for (const path of getNormalizedFilePaths(parsed.changes)) addPath(path);
  }

  if (toolIs(name, agentType, undefined, "codex/apply_patch")) {
    const rows = getApplyPatchFileChanges(input);
    for (const path of getNormalizedFilePaths(rows)) addPath(path);
  }

  return paths;
}

function deriveHunkTextPair(
  hunks: PatchHunk[] | undefined,
): { oldText: string; newText: string } | null {
  if (!hunks || hunks.length === 0) return null;
  const oldLines: string[] = [];
  const newLines: string[] = [];
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      const prefix = line[0];
      const content = line.slice(1);
      if (prefix === " " || prefix === "-") oldLines.push(content);
      if (prefix === " " || prefix === "+") newLines.push(content);
    }
  }
  if (oldLines.length === 0 && newLines.length === 0) return null;
  return { oldText: oldLines.join("\n"), newText: newLines.join("\n") };
}

function hasSufficientPatchContextForRenderedPreview(
  hunks: PatchHunk[] | undefined,
): boolean {
  if (!hunks || hunks.length === 0) return false;
  const first = hunks[0]!;
  if (first.oldStart !== 1 || first.newStart !== 1) return false;

  let expectedOldStart = 1;
  let expectedNewStart = 1;
  let sawContextLine = false;
  for (const hunk of hunks) {
    if (
      hunk.oldStart !== expectedOldStart ||
      hunk.newStart !== expectedNewStart
    ) {
      return false;
    }
    for (const line of hunk.lines) {
      if (line.startsWith(" ")) {
        sawContextLine = true;
        break;
      }
    }
    expectedOldStart += Math.max(hunk.oldLines, 1);
    expectedNewStart += Math.max(hunk.newLines, 1);
  }
  return sawContextLine;
}

function ChangePatchFallback({ change }: { change: NormalizedFileChange }) {
  const patchText = change.patchText ?? "";
  const tokens = useHighlight(patchText, "diff");
  return (
    <CodePre class="write-content" copyText={patchText}>
      {tokens ? renderTokenLines(tokens) : patchText}
    </CodePre>
  );
}

function ScriptContentPreview({
  content,
  language,
}: {
  content: string;
  language: string;
}) {
  const tokens = useHighlight(content, language);
  return (
    <CodePre class="write-content" copyText={content}>
      {tokens ? renderTokenLines(tokens) : content}
    </CodePre>
  );
}

function ApplyPatchFallback({ patchText }: { patchText: string }) {
  const patchTokens = useHighlight(patchText, "diff");
  return (
    <CodePre class="write-content" copyText={patchText}>
      {patchTokens ? renderTokenLines(patchTokens) : patchText}
    </CodePre>
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
  const format = detectRenderableFormat(filePath);
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
        <MarkdownDiffPreview
          oldText={oldString}
          newText={newString}
          filePath={filePath}
        />
      ) : format === "svg" ? (
        <SvgDiffPreview
          oldText={oldString}
          newText={newString}
          filePath={filePath}
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
      <FileContentPreview
        filePath={filePath}
        content={content}
        defaultSource={false}
      />
    </div>
  );
}

function FileChangeRow({
  change,
  showMeta,
  preservePatchSource = false,
}: {
  change: NormalizedFileChange;
  showMeta: boolean;
  preservePatchSource?: boolean;
}) {
  const path = change.path ?? undefined;
  const renderableContentFormat = detectRenderableFormat(path, change.content);
  const canRenderAddedContent =
    change.op === "add" &&
    typeof change.content === "string" &&
    renderableContentFormat != null;
  const patchTextPair = deriveHunkTextPair(change.patchHunks);
  const hasRenderablePatchContext = hasSufficientPatchContextForRenderedPreview(
    change.patchHunks,
  );
  const canRenderPatchMarkdown =
    isMarkdownPath(path) &&
    patchTextPair != null &&
    (patchTextPair.oldText.length > 0 || patchTextPair.newText.length > 0) &&
    hasRenderablePatchContext;
  const canRenderPatchSvg =
    isSvgPath(path) &&
    patchTextPair != null &&
    looksLikeSvg(patchTextPair.oldText) &&
    looksLikeSvg(patchTextPair.newText) &&
    hasRenderablePatchContext;
  const canRenderDiffMarkdown =
    typeof change.oldText === "string" &&
    typeof change.newText === "string" &&
    isMarkdownPath(path);
  const canRenderDiffSvg =
    typeof change.oldText === "string" &&
    typeof change.newText === "string" &&
    isSvgPath(path);
  const contentText = change.content ?? "";
  const contentLang = looksLikePatchText(contentText)
    ? "diff"
    : path
      ? langFromPath(path)
      : null;
  const contentTokens = useHighlight(contentText, contentLang);
  const shouldSuppressContentFallback =
    preservePatchSource && typeof change.patchText === "string";

  return (
    <div class="filechange-change">
      {showMeta && (
        <div class="tool-input-field filechange-meta">
          <span class="tool-subtitle-tag">{change.label}</span>
          <span class="tool-subtitle-path">
            {change.path ?? "(unknown file)"}
          </span>
        </div>
      )}
      {canRenderAddedContent &&
      preservePatchSource &&
      typeof change.patchText === "string" ? (
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={<ChangePatchFallback change={change} />}
          renderedView={
            <FileContentPreview
              filePath={path}
              content={change.content ?? ""}
              defaultSource={false}
            />
          }
        />
      ) : canRenderAddedContent ? (
        <FileContentPreview
          filePath={path}
          content={change.content ?? ""}
          defaultSource={false}
        />
      ) : null}
      {!canRenderAddedContent && canRenderDiffMarkdown && (
        <MarkdownDiffPreview
          oldText={change.oldText ?? ""}
          newText={change.newText ?? ""}
          filePath={path}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent && canRenderDiffSvg && (
        <SvgDiffPreview
          oldText={change.oldText ?? ""}
          newText={change.newText ?? ""}
          filePath={path}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        typeof change.oldText === "string" &&
        typeof change.newText === "string" && (
          <DiffView
            oldStr={change.oldText}
            newStr={change.newText}
            filePath={path}
          />
        )}
      {!canRenderAddedContent && canRenderPatchMarkdown && (
        <MarkdownDiffPreview
          oldText={patchTextPair.oldText}
          newText={patchTextPair.newText}
          filePath={path}
          sourceText={preservePatchSource ? change.patchText : undefined}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent && canRenderPatchSvg && (
        <SvgDiffPreview
          oldText={patchTextPair.oldText}
          newText={patchTextPair.newText}
          filePath={path}
          sourceText={preservePatchSource ? change.patchText : undefined}
          defaultSource={true}
        />
      )}
      {!canRenderAddedContent &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !preservePatchSource &&
        change.patchHunks &&
        change.patchHunks.length > 0 && (
          <PatchView hunks={change.patchHunks} filePath={path} />
        )}
      {!canRenderAddedContent &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        typeof change.patchText === "string" &&
        (preservePatchSource ||
          !change.patchHunks ||
          change.patchHunks.length === 0) && (
          <ChangePatchFallback change={change} />
        )}
      {!canRenderAddedContent &&
        typeof change.content === "string" &&
        typeof change.oldText !== "string" &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !shouldSuppressContentFallback &&
        renderableContentFormat != null && (
          <FileContentPreview
            filePath={path}
            content={change.content}
            defaultSource={false}
          />
        )}
      {!canRenderAddedContent &&
        typeof change.content === "string" &&
        typeof change.oldText !== "string" &&
        renderableContentFormat == null &&
        !canRenderDiffMarkdown &&
        !canRenderDiffSvg &&
        !canRenderPatchMarkdown &&
        !canRenderPatchSvg &&
        !shouldSuppressContentFallback && (
          <CodePre class="write-content" copyText={change.content}>
            {contentTokens ? renderTokenLines(contentTokens) : change.content}
          </CodePre>
        )}
    </div>
  );
}

function getSingleFileChangeHeaderSubtitle(
  input: Record<string, unknown>,
): h.JSX.Element | null {
  const { changes, unparsed } = parseCodexFileChanges(input);
  if (changes.length !== 1 || unparsed.length > 0) return null;

  const change = changes[0]!;
  if (!change.path) return null;

  return (
    <Fragment>
      <span class="tool-subtitle-tag">{change.label}</span>
      <span class="tool-subtitle-path">{change.path}</span>
    </Fragment>
  );
}

function FileChangeInput({ input }: { input: Record<string, unknown> }) {
  const { changes, unparsed } = parseCodexFileChanges(input);
  if (changes.length === 0) return formatGenericInput(input);
  const showRowMeta = changes.length > 1 || unparsed.length > 0;

  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k !== "changes") remaining[k] = v;
  }
  if (unparsed.length > 0) {
    remaining.changes = unparsed;
  }
  return formatGenericInput(
    remaining,
    <div class="filechange-list">
      {changes.map((change, i) => (
        <FileChangeRow key={i} change={change} showMeta={showRowMeta} />
      ))}
    </div>,
  );
}

function ApplyPatchInput({ input }: { input: Record<string, unknown> }) {
  const patchText = parsePatchTextFromInput(input);
  if (!patchText) return formatGenericInput(input);
  const changes = getApplyPatchFileChanges(input);

  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k === "input" || k === "patchText" || k === "patch" || k === "diff")
      continue;
    remaining[k] = v;
  }

  if (changes.length === 0) {
    return formatGenericInput(
      remaining,
      <ApplyPatchFallback patchText={patchText} />,
    );
  }

  const showRowMeta = changes.length > 1;
  return formatGenericInput(
    remaining,
    <div class="filechange-list">
      {changes.map((change, i) => (
        <FileChangeRow
          key={i}
          change={change}
          showMeta={showRowMeta}
          preservePatchSource={true}
        />
      ))}
    </div>,
  );
}

function ShellCommandInput({
  input,
  result,
}: {
  input: Record<string, unknown>;
  result?: ToolResult;
}) {
  const command = extractSemanticShellCommand(input, result);
  const semantic = useShellSemantic(command);
  const parsedSourceTree = useMemo(
    () => (command ? parseCommandSourceTree(command) : null),
    [command],
  );
  const isHeredocWrite =
    semantic?.ok === true && semantic.value.kind === "write";
  const isScriptExec =
    semantic?.ok === true && semantic.value.kind === "script-exec";
  const headerText = isHeredocWrite
    ? ((
        semantic as { ok: true; value: ShellHeredocWriteSemantic }
      ).value.segments.find((s) => s.kind === "command-header")?.text ?? "")
    : isScriptExec
      ? ((
          semantic as { ok: true; value: ShellScriptExecSemantic }
        ).value.segments.find((s) => s.kind === "command-header")?.text ?? "")
      : "";
  // All useHighlight calls must be unconditional (hooks rules).
  const tokens = useHighlight(command ?? "", "bash");
  const headerTokens = useHighlight(headerText.trimEnd(), "bash");
  const consumedKeys = new Set(["command", "cmd", "description"]);
  const remaining: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (!consumedKeys.has(k)) remaining[k] = v;
  }

  // Heredoc write: render header/content/footer
  if (isHeredocWrite) {
    const writeVal = (
      semantic as { ok: true; value: ShellHeredocWriteSemantic }
    ).value as ShellHeredocWriteSemantic & {
      inputSegments?: ShellInputSegment[];
    };
    const semanticSegments: ShellInputSegment[] = writeVal.inputSegments ?? [];
    const embeddedIdx = semanticSegments.findIndex(
      (s) => s.kind === "embedded-content" && s.role === "write-content",
    );
    const preTextFromSegments =
      embeddedIdx >= 0
        ? semanticSegments
            .slice(0, embeddedIdx)
            .map((s) => s.text)
            .join("")
        : null;
    const postTextFromSegments =
      embeddedIdx >= 0
        ? semanticSegments
            .slice(embeddedIdx + 1)
            .map((s) => s.text)
            .join("")
        : null;
    const writeSegment = writeVal.segments.find(
      (s) => s.kind === "write-content",
    );
    const footerText =
      postTextFromSegments ??
      writeVal.segments.find((s) => s.kind === "command-footer")?.text ??
      "";
    return formatGenericInput(
      remaining,
      <div class="semantic-shell-command" data-testid="semantic-shell-write">
        <CodePre class="write-content" copyText={command!}>
          {preTextFromSegments != null
            ? preTextFromSegments.replace(/\n$/, "")
            : headerTokens
              ? renderTokenLines(headerTokens)
              : headerText.trimEnd()}
        </CodePre>
        {writeSegment && (
          <FileContentPreview
            filePath={writeVal.filePath}
            content={writeSegment.text}
            defaultSource={false}
          />
        )}
        <CodePre class="write-content semantic-command-footer" copyText="">
          {footerText.replace(/^\n/, "")}
        </CodePre>
      </div>,
    );
  }

  // Heredoc script-exec: render header/script-content/footer
  if (
    isScriptExec &&
    (semantic as { ok: true; value: ShellScriptExecSemantic }).value
      .scriptSource.type === "heredoc"
  ) {
    const scriptVal = (semantic as { ok: true; value: ShellScriptExecSemantic })
      .value as ShellScriptExecSemantic & {
      inputSegments?: ShellInputSegment[];
    };
    const semanticSegments: ShellInputSegment[] = scriptVal.inputSegments ?? [];
    const embeddedIdx = semanticSegments.findIndex(
      (s) => s.kind === "embedded-content" && s.role === "script-content",
    );
    const preTextFromSegments =
      embeddedIdx >= 0
        ? semanticSegments
            .slice(0, embeddedIdx)
            .map((s) => s.text)
            .join("")
        : null;
    const postTextFromSegments =
      embeddedIdx >= 0
        ? semanticSegments
            .slice(embeddedIdx + 1)
            .map((s) => s.text)
            .join("")
        : null;
    const scriptSegment = scriptVal.segments.find(
      (s) => s.kind === "script-content",
    );
    const footerText =
      postTextFromSegments ??
      scriptVal.segments.find((s) => s.kind === "command-footer")?.text ??
      "";
    return formatGenericInput(
      remaining,
      <div class="semantic-shell-command" data-testid="semantic-shell-script">
        <CodePre class="write-content" copyText={command!}>
          {preTextFromSegments != null
            ? preTextFromSegments.replace(/\n$/, "")
            : headerTokens
              ? renderTokenLines(headerTokens)
              : headerText.trimEnd()}
        </CodePre>
        {scriptSegment && (
          <ScriptContentPreview
            content={scriptSegment.text}
            language={scriptVal.language}
          />
        )}
        <CodePre class="write-content semantic-command-footer" copyText="">
          {footerText.replace(/^\n/, "")}
        </CodePre>
      </div>,
    );
  }

  if (command && parsedSourceTree?.ok) {
    const sourceTreeView = (
      <SourceNodeView
        root={parsedSourceTree.value}
        copyText={parsedSourceTree.value.text}
      />
    );
    const isWrapperView = hasWrapperSourceTree(parsedSourceTree.value);
    return formatGenericInput(
      remaining,
      isWrapperView ? (
        <div data-testid="semantic-shell-wrapper-input">{sourceTreeView}</div>
      ) : (
        sourceTreeView
      ),
    );
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

function hasWrapperSourceTree(root: SourceNode): boolean {
  return root.segments.some(
    (segment) =>
      segment.kind === "embed" &&
      (segment.escaping.kind === "shell-single-quote" ||
        segment.escaping.kind === "shell-double-quote"),
  );
}

function ReadResult({
  content,
  filePath,
}: {
  content: string;
  filePath: string;
}) {
  const format = detectRenderableFormat(filePath);
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

function WebSearchResult({
  content,
  toolResult,
}: {
  content: string | null;
  toolResult?: Record<string, unknown> | null;
}) {
  // Try Claude text format first
  const iterations = content ? parseWebSearchResult(content) : null;
  if (iterations) {
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

  // Codex structured format: toolResult has { query, queries }
  if (toolResult) {
    const queries: string[] = Array.isArray(toolResult.queries)
      ? (toolResult.queries as string[])
      : typeof toolResult.query === "string"
        ? [toolResult.query]
        : [];
    if (queries.length > 0) {
      return (
        <div class="tool-result-blocks">
          {queries.map((q, i) => (
            <div class="web-search-iteration" key={i}>
              <div class="web-search-query">"{q}"</div>
            </div>
          ))}
        </div>
      );
    }
  }

  // Fallback: raw text
  return (
    <CodePre class="tool-result" copyText={content ?? ""}>
      {content ?? ""}
    </CodePre>
  );
}

export function parseCydoTaskResultPayload(payload: unknown): unknown[] | null {
  const parsedObj =
    !Array.isArray(payload) && typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>)
      : null;
  if (parsedObj?.structuredContent !== undefined) {
    const structuredItems = parseCydoTaskResultPayload(
      parsedObj.structuredContent,
    );
    if (structuredItems) return structuredItems;
  }
  const arr: unknown[] | null = Array.isArray(payload)
    ? payload
    : Array.isArray(parsedObj?.tasks)
      ? parsedObj.tasks
      : parsedObj != null &&
          [
            "status",
            "tid",
            "qid",
            "title",
            "message",
            "summary",
            "error",
            "note",
            "output_file",
            "worktree",
            "commits",
          ].some((key) => key in parsedObj)
        ? [parsedObj]
        : null;
  return arr && arr.length > 0 ? arr : null;
}

export function parseCydoTaskResult(content: string): unknown[] | null {
  try {
    return parseCydoTaskResultPayload(JSON.parse(content) as unknown);
  } catch {
    return null;
  }
}

export function getCydoTaskResultItems(
  result: ToolResult | undefined,
): unknown[] | null {
  if (!result) return null;
  const structuredItems = parseCydoTaskResultPayload(result.toolResult);
  if (structuredItems) return structuredItems;
  const resultText = extractResultText(result.content);
  return resultText != null ? parseCydoTaskResult(resultText) : null;
}

export function formatCydoTaskResultItem(item: Record<string, unknown>): {
  fields: Record<string, unknown>;
  text: string | null;
} {
  const text =
    typeof item.error === "string"
      ? item.error
      : typeof item.message === "string"
        ? item.message
        : typeof item.summary === "string"
          ? item.summary
          : typeof item.result === "string"
            ? item.result
            : typeof item.note === "string"
              ? item.note
              : null;
  const {
    error: _error,
    message: _message,
    summary,
    result: _result,
    note: _note,
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

// Map qualified tool key → set of known (ignored + consumed) toolResult field names.
const knownResultFields: Record<string, Set<string>> = {
  "claude/Bash": new Set([
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
  "codex/commandExecution": new Set([
    "exitCode",
    "status",
    "durationMs",
    "command",
    "cwd",
    "processId",
    "commandActions",
  ]),
  "codex/local_shell_call": new Set([]),
  "codex/exec_command": new Set([]),
  "claude/Read": new Set(["type", "file"]),
  "claude/Edit": new Set([
    "filePath",
    "oldString",
    "newString",
    "replaceAll",
    "originalFile",
    "structuredPatch",
    "userModified",
  ]),
  "claude/Write": new Set([
    "type",
    "filePath",
    "content",
    "originalFile",
    "structuredPatch",
  ]),
  "codex/fileChange": new Set([]),
  "claude/Glob": new Set(["filenames", "numFiles", "truncated", "durationMs"]),
  "claude/Grep": new Set([
    "mode",
    "filenames",
    "numFiles",
    "content",
    "numLines",
    "numMatches",
    "appliedLimit",
    "appliedOffset",
  ]),
  "claude/TodoWrite": new Set(["oldTodos", "newTodos"]),
  "claude/WebSearch": new Set(["query", "results", "durationSeconds"]),
  "codex/webSearch": new Set(["query", "queries"]),
  "claude/WebFetch": new Set([
    "url",
    "code",
    "codeText",
    "result",
    "bytes",
    "durationMs",
  ]),
  "claude/AskUserQuestion": new Set(["questions", "answers", "annotations"]),
  "cydo:AskUserQuestion": new Set(["questions", "answers"]),
  "claude/Task": new Set([
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
  "claude/TaskCreate": new Set(["task"]),
  "claude/TaskGet": new Set(["task"]),
  "claude/TaskList": new Set(["tasks"]),
  "claude/TaskOutput": new Set(["retrieval_status", "task"]),
  "claude/TaskStop": new Set(["message", "task_id", "task_type", "command"]),
  "claude/TaskUpdate": new Set([
    "success",
    "taskId",
    "updatedFields",
    "statusChange",
    "error",
  ]),
  "claude/TeamCreate": new Set([
    "team_name",
    "team_file_path",
    "lead_agent_id",
  ]),
  "claude/TeamDelete": new Set(["success", "message", "team_name"]),
  "claude/SendMessage": new Set([
    "success",
    "message",
    "request_id",
    "target",
    "routing",
  ]),
  "claude/Skill": new Set(["success", "commandName", "allowedTools"]),
  "claude/EnterPlanMode": new Set(["message"]),
  "claude/ExitPlanMode": new Set([
    "plan",
    "filePath",
    "isAgent",
    "hasTaskTool",
  ]),
  "claude/NotebookEdit": new Set([]),
  "cydo:Task": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "qid",
    "summary",
    "error",
    "title",
    "message",
    "note",
    "output_file",
    "worktree",
    "commits",
  ]),
  "cydo:Ask": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "qid",
    "summary",
    "error",
    "title",
    "message",
    "note",
    "output_file",
    "worktree",
    "commits",
  ]),
  "cydo:Answer": new Set([
    "tasks",
    "content",
    "structuredContent",
    "status",
    "tid",
    "qid",
    "summary",
    "error",
    "title",
    "message",
    "note",
    "output_file",
    "worktree",
    "commits",
  ]),
  "cydo:SwitchMode": new Set(["message"]),
  "cydo:Handoff": new Set(["message"]),
};

function formatToolUseResult(
  name: string,
  toolServer: string | undefined,
  agentType: string | undefined,
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

  const known =
    knownResultFields[qualifiedToolKey(name, toolServer, agentType)];
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

function PathDisplay({ path }: { path: string }) {
  const slash = path.lastIndexOf("/");
  return (
    <span class="tool-path-wrap">
      <span class="tool-subtitle-path">
        {slash === -1 ? (
          path
        ) : (
          <>
            <span class="tool-path-prefix">{path.slice(0, slash)}/</span>
            <span class="tool-path-leaf">{path.slice(slash + 1)}</span>
          </>
        )}
      </span>
      <span
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <CopyButton text={path} />
      </span>
    </span>
  );
}

function getHeaderSubtitle(
  name: string,
  toolServer: string | undefined,
  agentType: string | undefined,
  input: Record<string, unknown>,
): h.JSX.Element | null {
  const viewPaths = getToolCallFilePaths(name, agentType, input);
  const filePath = typeof input.file_path === "string" ? input.file_path : null;

  if (toolIs(name, agentType, toolServer, "claude/Edit") && filePath) {
    return (
      <Fragment>
        <PathDisplay path={filePath} />
        {input.replace_all && <span class="tool-subtitle-tag">all</span>}
      </Fragment>
    );
  }
  if (isFileWriteTool(name, agentType) && filePath) {
    return <PathDisplay path={filePath} />;
  }
  if (toolIs(name, agentType, toolServer, "codex/fileChange")) {
    const singleFileSubtitle = getSingleFileChangeHeaderSubtitle(input);
    if (singleFileSubtitle) return singleFileSubtitle;
    if (viewPaths.length > 1) {
      return <span class="tool-subtitle">{viewPaths.length} files</span>;
    }
  }
  if (toolIs(name, agentType, toolServer, "codex/apply_patch")) {
    if (viewPaths.length === 1) {
      return <PathDisplay path={viewPaths[0]!} />;
    }
    if (viewPaths.length > 1) {
      return <span class="tool-subtitle">{viewPaths.length} files</span>;
    }
  }
  if (toolIs(name, agentType, toolServer, "claude/Read") && filePath) {
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
        <PathDisplay path={filePath} />
        {range && <span class="tool-subtitle">{range}</span>}
      </Fragment>
    );
  }
  if (
    toolIs(name, agentType, toolServer, "copilot/view") &&
    typeof input.path === "string"
  ) {
    const vr = Array.isArray(input.view_range) ? input.view_range : null;
    const range =
      vr && vr.length === 2
        ? `(${vr[0]}\u2013${vr[1]})`
        : vr && vr.length === 1
          ? `(${vr[0]}\u2013)`
          : null;
    return (
      <Fragment>
        <PathDisplay path={input.path} />
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
            <PathDisplay path={path} />
          </Fragment>
        )}
      </Fragment>
    );
  }
  if (
    toolIs(
      name,
      agentType,
      toolServer,
      "claude/AskUserQuestion",
      "cydo:AskUserQuestion",
    ) &&
    Array.isArray(input.questions)
  ) {
    const questions = input.questions as AskQuestion[];
    if (questions.length === 1) {
      return <span class="tool-subtitle">{questions[0]!.header}</span>;
    }
    return <span class="tool-subtitle">{questions.length} questions</span>;
  }
  if (
    toolIs(
      name,
      agentType,
      toolServer,
      "claude/WebSearch",
      "codex/webSearch",
    ) &&
    typeof input.query === "string"
  ) {
    return <span class="tool-subtitle">{input.query}</span>;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/WebFetch") &&
    typeof input.url === "string"
  ) {
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
  if (
    isShellTool(name, agentType, toolServer) &&
    typeof input.description === "string"
  ) {
    return <span class="tool-subtitle">{input.description}</span>;
  }
  if (
    toolIs(name, agentType, toolServer, "copilot/report_intent") &&
    typeof input.intent === "string"
  ) {
    return <span class="tool-subtitle">{input.intent}</span>;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/Task", "copilot/task") &&
    typeof input.description === "string"
  ) {
    const subagentType =
      typeof input.subagent_type === "string"
        ? input.subagent_type
        : typeof input.agent_type === "string"
          ? input.agent_type
          : null;
    return (
      <Fragment>
        {subagentType && <span class="tool-subtitle-tag">{subagentType}</span>}
        <span class="tool-subtitle">{input.description}</span>
      </Fragment>
    );
  }
  // --- CyDo MCP tools ---
  if (
    toolIs(name, agentType, toolServer, "cydo:SwitchMode") &&
    typeof input.continuation === "string"
  ) {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (
    toolIs(name, agentType, toolServer, "cydo:Handoff") &&
    typeof input.continuation === "string"
  ) {
    return <span class="tool-subtitle">{input.continuation}</span>;
  }
  if (toolIs(name, agentType, toolServer, "cydo:Task")) {
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
  if (toolIs(name, agentType, toolServer, "claude/SendMessage")) {
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
  if (toolIs(name, agentType, toolServer, "claude/TaskCreate")) {
    const tasks = input.tasks as Array<{ description?: string }> | undefined;
    if (Array.isArray(tasks)) {
      if (tasks.length === 1 && tasks[0]!.description) {
        return <span class="tool-subtitle">{tasks[0]!.description}</span>;
      }
      return <span class="tool-subtitle">{tasks.length} tasks</span>;
    }
  }
  if (toolIs(name, agentType, toolServer, "claude/TaskUpdate")) {
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
  if (toolIs(name, agentType, toolServer, "claude/TaskOutput")) {
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
  if (toolIs(name, agentType, toolServer, "claude/TaskStop")) {
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
  if (
    toolIs(name, agentType, toolServer, "claude/Skill") &&
    typeof input.skill === "string"
  ) {
    return <span class="tool-subtitle">{input.skill}</span>;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/TeamCreate") &&
    typeof input.team_name === "string"
  ) {
    return <span class="tool-subtitle">{input.team_name}</span>;
  }
  if (toolIs(name, agentType, toolServer, "claude/EnterWorktree")) {
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
  agentType: string | undefined,
  input: Record<string, unknown>,
  result?: ToolResult,
): h.JSX.Element {
  if (
    toolIs(name, agentType, toolServer, "codex/fileChange") &&
    Array.isArray(input.changes)
  ) {
    return <FileChangeInput input={input} />;
  }
  if (toolIs(name, agentType, toolServer, "codex/apply_patch")) {
    return <ApplyPatchInput input={input} />;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/Edit") &&
    "old_string" in input &&
    "new_string" in input
  ) {
    return <EditInput input={input} result={result} />;
  }
  if (
    isFileWriteTool(name, agentType) &&
    "file_path" in input &&
    "content" in input
  ) {
    return <WriteInput input={input} />;
  }
  if (
    (toolIs(name, agentType, toolServer, "claude/TodoWrite") ||
      "todos" in input) &&
    Array.isArray(input.todos)
  ) {
    return formatTodoWriteInput(input);
  }
  if (
    toolIs(
      name,
      agentType,
      toolServer,
      "claude/AskUserQuestion",
      "cydo:AskUserQuestion",
    ) &&
    Array.isArray(input.questions)
  ) {
    return <AskUserQuestionInput input={input} result={result} />;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/ExitPlanMode") &&
    typeof input.plan === "string"
  ) {
    const { plan, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={plan} />);
  }
  if (
    toolIs(name, agentType, toolServer, "claude/Task", "copilot/task") &&
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
  if (
    toolIs(
      name,
      agentType,
      toolServer,
      "claude/WebSearch",
      "codex/webSearch",
    ) &&
    typeof input.query === "string"
  ) {
    const { query, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (
    toolIs(name, agentType, toolServer, "claude/WebFetch") &&
    typeof input.url === "string"
  ) {
    const { url, prompt, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof prompt === "string" ? <Markdown text={prompt} /> : undefined,
    );
  }
  if (
    isShellTool(name, agentType, toolServer) &&
    (typeof input.command === "string" || typeof input.cmd === "string")
  ) {
    return <ShellCommandInput input={input} result={result} />;
  }
  if (
    toolIs(name, agentType, toolServer, "claude/Read") &&
    typeof input.file_path === "string"
  ) {
    const { file_path, offset, limit, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (
    toolIs(name, agentType, toolServer, "copilot/view") &&
    typeof input.path === "string"
  ) {
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
    toolIs(name, agentType, toolServer, "cydo:Ask", "cydo:Answer") &&
    typeof input.message === "string"
  ) {
    const { message, ...remaining } = input;
    return formatGenericInput(remaining, <Markdown text={message} />);
  }
  if (
    toolIs(name, agentType, toolServer, "cydo:Task") &&
    Array.isArray(input.tasks)
  ) {
    return formatTaskSpecsInput(input.tasks as Array<Record<string, unknown>>);
  }
  if (toolIs(name, agentType, toolServer, "cydo:Handoff")) {
    const { continuation, prompt: handoffPrompt, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof handoffPrompt === "string" ? (
        <Markdown text={handoffPrompt} />
      ) : undefined,
    );
  }
  // --- Claude Code built-in tools ---
  if (toolIs(name, agentType, toolServer, "claude/SendMessage")) {
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
  if (toolIs(name, agentType, toolServer, "claude/Skill")) {
    const { skill, args: skillArgs, ...remaining } = input;
    return formatGenericInput(
      remaining,
      typeof skillArgs === "string" ? (
        <pre class="write-content">{skillArgs}</pre>
      ) : undefined,
    );
  }
  if (
    toolIs(name, agentType, toolServer, "claude/TaskCreate") &&
    Array.isArray(input.tasks)
  ) {
    return formatTaskSpecsInput(input.tasks as Array<Record<string, unknown>>);
  }
  if (toolIs(name, agentType, toolServer, "claude/TaskUpdate")) {
    const { task_id, taskId, status, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (toolIs(name, agentType, toolServer, "claude/TaskOutput")) {
    const { task_id, block, timeout, ...remaining } = input;
    return formatGenericInput(remaining);
  }
  if (toolIs(name, agentType, toolServer, "claude/TaskStop")) {
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

function extractShellStdout(
  name: string,
  toolServer: string | undefined,
  agentType: string | undefined,
  result: ToolResult | undefined,
): string | null {
  if (!result || result.isError) return null;
  if (toolIs(name, agentType, toolServer, "claude/Bash")) {
    const tr = result.toolResult as Record<string, unknown> | undefined;
    return typeof tr?.stdout === "string" ? tr.stdout : null;
  }
  if (
    toolIs(
      name,
      agentType,
      toolServer,
      "codex/commandExecution",
      "codex/local_shell_call",
    )
  ) {
    const tr = result.toolResult as Record<string, unknown> | undefined;
    const fromToolResult =
      (typeof tr?.stdout === "string" && tr.stdout) ||
      (typeof tr?.aggregatedOutput === "string" && tr.aggregatedOutput) ||
      (typeof tr?.aggregated_output === "string" && tr.aggregated_output) ||
      (typeof tr?.formattedOutput === "string" && tr.formattedOutput) ||
      (typeof tr?.formatted_output === "string" && tr.formatted_output) ||
      null;
    if (fromToolResult != null) return fromToolResult;
  }
  if (toolIs(name, agentType, toolServer, "codex/exec_command")) {
    const text = extractResultText(result.content);
    return text != null ? parseExecCommandOutput(text) : null;
  }
  return extractResultText(result.content);
}

function ExecCommandResult({ content }: { content: string }) {
  const output = parseExecCommandOutput(content);
  return <ResultPre content={output} />;
}

function DiffResult({ content }: { content: string }) {
  const tokens = useHighlight(content, "diff");
  const sections = parseApplyPatchSections(content);
  if (sections.length > 0) {
    return (
      <>
        {sections.map((section, i) => {
          const hunks = parsePatchHunksFromText(section.patchText);
          if (hunks && hunks.length > 0) {
            return <PatchView key={i} hunks={hunks} filePath={section.path} />;
          }
          return null;
        })}
      </>
    );
  }
  const hunks = parsePatchHunksFromText(content);
  if (hunks && hunks.length > 0) {
    return <PatchView hunks={hunks} />;
  }
  return (
    <ResultPre content={content}>
      {tokens ? renderTokenLines(tokens) : content}
    </ResultPre>
  );
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
  const format = detectRenderableFormat(null, content);
  const trimmed = content.trimStart();
  const isJson =
    !format &&
    (trimmed.startsWith("{") || trimmed.startsWith("[")) &&
    (() => {
      try {
        JSON.parse(content);
        return true;
      } catch {
        return false;
      }
    })();
  const highlightLang = format === "svg" ? "xml" : isJson ? "json" : null;
  const tokens = useHighlight(content, highlightLang);

  if (!format) {
    return (
      <ResultPre content={content} isError={isError}>
        {tokens
          ? renderTokenLines(tokens)
          : hasAnsi(content)
            ? renderAnsi(content)
            : content}
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

  return <SmartResultPre content={text} isError={isError} />;
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
  "claude/Edit",
  "claude/Write",
  "codex/fileChange",
  "codex/apply_patch",
  "claude/Bash",
  "codex/commandExecution",
  "codex/local_shell_call",
  "codex/exec_command",
  "claude/ExitPlanMode",
  "claude/TodoWrite",
  "claude/AskUserQuestion",
  "claude/WebFetch",
  "claude/Task",
  "cydo:Task",
  "copilot/task",
  "cydo:Ask",
  "cydo:Answer",
  "cydo:Handoff",
  "cydo:AskUserQuestion",
  "cydo:Bash", // CyDo MCP Bash tool (used by Copilot/Codex)
  "claude/SendMessage",
  "claude/TaskCreate",
  "copilot/bash",
]);
const defaultExpandedResults = new Set([
  "claude/Bash",
  "copilot/bash",
  "cydo:Bash", // Copilot calls CyDo's cydo-Bash MCP tool, which arrives as name="Bash", toolServer="cydo"
  "codex/commandExecution",
  "codex/local_shell_call",
  "codex/exec_command",
  "claude/Task",
  "cydo:Task",
  "copilot/task",
  "cydo:Ask",
  "cydo:Answer",
  "claude/WebSearch",
  "codex/webSearch",
  "claude/WebFetch",
  "claude/TaskOutput",
  "claude/TaskStop",
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

function defaultResultExpanded(
  name: string,
  toolServer: string | undefined,
  agentType: string | undefined,
  result?: ToolResult,
): boolean {
  if (
    toolIs(name, agentType, toolServer, "codex/commandExecution") &&
    hasReadOnlyCommandActions(result)
  )
    return false;
  return defaultExpandedResults.has(
    qualifiedToolKey(name, toolServer, agentType),
  );
}

const askToolNames = new Set([
  "claude/AskUserQuestion",
  "cydo:AskUserQuestion",
]);

export const ToolCall = memo(
  function ToolCall({
    name,
    toolServer,
    agentType,
    toolUseId,
    input,
    result,
    streaming,
    children,
    onViewFile,
  }: Props) {
    // Collapse pending AskUserQuestion input — the interactive form shows the same content
    const qKey = qualifiedToolKey(name, toolServer, agentType);
    const isAsk = askToolNames.has(qKey);
    const [inputOpen, setInputOpen] = useState(
      isAsk ? !!result : defaultExpandedTools.has(qKey),
    );
    // Auto-expand when result arrives for ask tools
    useEffect(() => {
      if (isAsk && result) setInputOpen(true);
    }, [isAsk, !!result]);
    const [resultOpenOverride, setResultOpenOverride] = useState<
      boolean | null
    >(null);
    const userToggledInput = useRef(false);
    const userToggledResult = useRef(false);
    const resultOpen =
      resultOpenOverride ??
      defaultResultExpanded(name, toolServer, agentType, result);
    const subtitle = getHeaderSubtitle(name, toolServer, agentType, input);
    const viewPaths = onViewFile
      ? getToolCallFilePaths(name, agentType, input)
      : [];

    const filePath =
      typeof input.file_path === "string"
        ? input.file_path
        : toolIs(name, agentType, toolServer, "copilot/view") &&
            typeof input.path === "string"
          ? input.path
          : null;
    const resultText = result ? extractResultText(result.content) : null;
    const cydoTaskItems = toolIs(
      name,
      agentType,
      toolServer,
      "cydo:Task",
      "cydo:Ask",
      "cydo:Answer",
    )
      ? getCydoTaskResultItems(result)
      : null;
    const useReadHighlight =
      toolIs(name, agentType, toolServer, "claude/Read", "copilot/view") &&
      filePath &&
      resultText != null &&
      !result!.isError;
    const useExecCommandResult =
      toolIs(name, agentType, toolServer, "codex/exec_command") &&
      resultText != null &&
      !result!.isError;
    const useWebSearchResult =
      toolIs(
        name,
        agentType,
        toolServer,
        "claude/WebSearch",
        "codex/webSearch",
      ) &&
      result != null &&
      !result.isError &&
      (resultText != null ||
        (result.toolResult != null && typeof result.toolResult === "object"));
    const useWebFetchResult =
      toolIs(name, agentType, toolServer, "claude/WebFetch") &&
      resultText != null &&
      !result!.isError;
    const useTaskOutputResult =
      toolIs(name, agentType, toolServer, "claude/TaskOutput") &&
      result &&
      !result.isError &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const useTaskStopResult =
      toolIs(name, agentType, toolServer, "claude/TaskStop") &&
      result &&
      !result.isError &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const useCommandExecutionResult =
      toolIs(name, agentType, toolServer, "codex/commandExecution") &&
      result != null &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const useBashResult =
      toolIs(name, agentType, toolServer, "claude/Bash") &&
      result != null &&
      result.toolResult != null &&
      typeof result.toolResult === "object";
    const shellCommand = isShellTool(name, agentType, toolServer)
      ? extractSemanticShellCommand(input, result)
      : null;
    const shellSemantic = useShellSemantic(shellCommand);
    const useSemanticShellRead =
      shellSemantic?.ok === true &&
      shellSemantic.value.kind === "read" &&
      result != null &&
      !result.isError;
    const semanticShellStdout = useSemanticShellRead
      ? extractShellStdout(name, toolServer, agentType, result)
      : null;
    const semanticReadFilePath =
      shellSemantic?.ok === true && shellSemantic.value.kind === "read"
        ? shellSemantic.value.filePath
        : null;
    const useSemanticShellDiff =
      shellSemantic?.ok === true &&
      shellSemantic.value.kind === "diff" &&
      result != null &&
      !result.isError;
    const semanticShellDiffStdout = useSemanticShellDiff
      ? extractShellStdout(name, toolServer, agentType, result)
      : null;
    const semanticOutputPlan =
      shellSemantic?.ok === true ? shellSemantic.value.outputPlan : undefined;
    const semanticOutputStdout =
      semanticOutputPlan && result != null && !result.isError
        ? extractShellStdout(name, toolServer, agentType, result)
        : null;
    const semanticOutputElement =
      semanticOutputPlan != null &&
      semanticOutputStdout != null &&
      hasSemanticShellOutput(semanticOutputStdout, semanticOutputPlan) ? (
        <SemanticShellOutput
          stdout={semanticOutputStdout}
          outputPlan={semanticOutputPlan}
        />
      ) : null;
    const shouldRenderSemanticOutput = semanticOutputElement != null;
    const semanticKind =
      shellSemantic?.ok === true ? shellSemantic.value.kind : null;
    const hasSemanticOutputPlan =
      shellSemantic?.ok === true && shellSemantic.value.outputPlan != null;
    // Semantic shell: adjust input/result expand defaults after classification.
    // Reads/diffs → collapse input (command is secondary), expand result (file content primary).
    // Writes → keep input expanded, collapse result (usually empty).
    useEffect(() => {
      if (semanticKind == null) return;
      if (hasSemanticOutputPlan) {
        if (!userToggledResult.current && resultOpenOverride === null)
          setResultOpenOverride(true);
      }
      const kind = semanticKind;
      if (kind === "read" || kind === "diff") {
        if (!userToggledInput.current) setInputOpen(false);
        if (!userToggledResult.current && resultOpenOverride === null)
          setResultOpenOverride(true);
      } else if (kind === "write") {
        if (
          !hasSemanticOutputPlan &&
          !userToggledResult.current &&
          resultOpenOverride === null
        )
          setResultOpenOverride(false);
      }
      // script-exec: no override, use defaults (both expanded)
    }, [semanticKind, hasSemanticOutputPlan]);
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
        class={`tool-call${streaming ? " streaming" : ""}${
          result?.isError ? " tool-error" : ""
        }`}
      >
        <div
          class="tool-header"
          onClick={() => {
            userToggledInput.current = true;
            setInputOpen(!inputOpen);
          }}
        >
          <span class="tool-icon">
            {result ? (
              result.isError ? (
                <span
                  class="action-icon"
                  dangerouslySetInnerHTML={{ __html: errorIcon }}
                />
              ) : (
                <span
                  class="action-icon"
                  dangerouslySetInnerHTML={{ __html: checkIcon }}
                />
              )
            ) : (
              <svg
                class="tool-icon-spinner"
                width="16"
                height="16"
                viewBox="0 0 16 16"
              >
                <circle
                  cx="8"
                  cy="8"
                  r="6"
                  fill="none"
                  stroke-width="2"
                  stroke="var(--border)"
                />
                <circle
                  cx="8"
                  cy="8"
                  r="6"
                  fill="none"
                  stroke-width="2"
                  stroke="var(--accent)"
                  stroke-dasharray="12 26"
                  stroke-linecap="round"
                />
              </svg>
            )}
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
          {(toolIs(name, agentType, toolServer, "claude/Edit") ||
            toolIs(name, agentType, toolServer, "codex/apply_patch") ||
            isFileWriteTool(name, agentType)) &&
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
        {inputOpen && formatInput(name, toolServer, agentType, input, result)}
        {children}
        {result && hasResultContent && (
          <div class="tool-result-section">
            <div
              class="tool-result-header"
              onClick={() => {
                userToggledResult.current = true;
                setResultOpenOverride(!resultOpen);
              }}
            >
              {resultOpen ? "\u25BC" : "\u25B6"} Result
            </div>
            {resultOpen && (
              <>
                <div class="tool-result-container">
                  {!useReadHighlight && resultImagesElement}
                  {shouldRenderSemanticOutput ? (
                    semanticOutputElement
                  ) : semanticShellStdout != null &&
                    semanticReadFilePath != null ? (
                    <div data-testid="semantic-shell-read">
                      <ReadResult
                        content={semanticShellStdout}
                        filePath={semanticReadFilePath}
                      />
                    </div>
                  ) : semanticShellDiffStdout != null ? (
                    <div data-testid="semantic-shell-diff">
                      <DiffResult content={semanticShellDiffStdout} />
                    </div>
                  ) : cydoTaskItems ? (
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
                    <WebSearchResult
                      content={resultText}
                      toolResult={
                        result.toolResult != null &&
                        typeof result.toolResult === "object"
                          ? (result.toolResult as Record<string, unknown>)
                          : null
                      }
                    />
                  ) : useWebFetchResult ? (
                    <div class="tool-result-blocks">
                      <Markdown text={resultText} class="text-content" />
                    </div>
                  ) : taskOutputElement ? (
                    taskOutputElement
                  ) : taskStopElement ? (
                    taskStopElement
                  ) : useBashResult ? (
                    (result.toolResult as Record<string, unknown>).stdout &&
                    !useSemanticShellRead &&
                    !useSemanticShellDiff ? (
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
                    agentType,
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
    prev.agentType === next.agentType &&
    prev.toolUseId === next.toolUseId &&
    prev.input === next.input &&
    prev.result === next.result &&
    prev.streaming === next.streaming &&
    prev.children === next.children &&
    prev.onViewFile === next.onViewFile,
);
