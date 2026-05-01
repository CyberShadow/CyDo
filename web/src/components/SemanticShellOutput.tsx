import { h, Fragment } from "preact";
import { useMemo } from "preact/hooks";
import { type ThemedToken, useHighlight, renderTokens } from "../highlight";
import { Markdown } from "./Markdown";
import { CodePre, CopyButton } from "./CopyButton";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";
import { FileContentPreview } from "./file-preview/FileContentPreview";
import { detectRenderableFormat } from "../lib/fileFormats";
import {
  segmentOutput,
  type OutputFormat,
  type OutputPlan,
  type OutputBlockPlan,
  type SegmentedOutputPiece,
} from "../lib/shellOutputPlan";

function renderTokenLines(tokens: ThemedToken[][] | null): h.JSX.Element {
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

function splitLogicalLines(text: string): string[] {
  if (text.length === 0) return [];
  const lines: string[] = [];
  let start = 0;
  while (start < text.length) {
    const nl = text.indexOf("\n", start);
    if (nl < 0) {
      lines.push(text.slice(start));
      break;
    }
    lines.push(text.slice(start, nl + 1));
    start = nl + 1;
  }
  return lines;
}

function InlineFormatted({
  text,
  format,
}: {
  text: string;
  format: OutputFormat;
}): h.JSX.Element {
  const codeLanguage =
    format.kind === "content" &&
    format.language !== "text" &&
    format.language !== "shell-output" &&
    format.language !== "markdown"
      ? format.language
      : null;
  const tokens = useHighlight(codeLanguage ? text : null, codeLanguage);

  if (format.kind === "content") {
    if (!codeLanguage) return <>{text}</>;
    return <>{renderTokenLines(tokens)}</>;
  }

  if (format.kind === "line-number-prefixed") {
    const lines = splitLogicalLines(text);
    return (
      <>
        {lines.map((line, i) => {
          const colon = line.indexOf(":");
          if (colon < 0) {
            return (
              <InlineFormatted key={i} text={line} format={format.format} />
            );
          }
          const prefix = line.slice(0, colon + 1);
          const suffix = line.slice(colon + 1);
          return (
            <Fragment key={i}>
              <span
                class="line-number"
                data-testid="semantic-shell-line-prefix"
              >
                {prefix}
              </span>
              <InlineFormatted text={suffix} format={format.format} />
            </Fragment>
          );
        })}
      </>
    );
  }

  const lines = splitLogicalLines(text);
  return (
    <>
      {lines.map((line, i) => (
        <InlineFormatted key={i} text={line} format={format.format} />
      ))}
    </>
  );
}

function StructuredContent({
  text,
  format,
  sourceFilePath,
  allowFilePreview,
}: {
  text: string;
  format: OutputFormat;
  sourceFilePath?: string;
  allowFilePreview: boolean;
}): h.JSX.Element {
  const codeLanguage =
    format.kind === "content" &&
    format.language !== "markdown" &&
    format.language !== "shell-output" &&
    format.language !== "text"
      ? format.language
      : null;
  const highlightedCode = useHighlight(
    codeLanguage ? text : null,
    codeLanguage,
  );

  if (format.kind === "content") {
    if (
      allowFilePreview &&
      sourceFilePath &&
      detectRenderableFormat(sourceFilePath, text) != null
    ) {
      return <FileContentPreview filePath={sourceFilePath} content={text} />;
    }

    if (format.language === "markdown") {
      return (
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={
            <CodePre class="tool-result" copyText={text}>
              {text}
            </CodePre>
          }
          renderedView={<Markdown text={text} class="text-content" />}
        />
      );
    }

    if (format.language === "shell-output" || format.language === "text") {
      return (
        <CodePre class="tool-result" copyText={text}>
          {text}
        </CodePre>
      );
    }

    return (
      <CodePre class="tool-result" copyText={text}>
        {highlightedCode ? renderTokenLines(highlightedCode) : text}
      </CodePre>
    );
  }

  return (
    <CodePre class="tool-result" copyText={text}>
      <InlineFormatted text={text} format={format} />
    </CodePre>
  );
}

function canRenderStructuredFilePreview(
  piece: Extract<SegmentedOutputPiece, { kind: "structured" }>,
  block: OutputBlockPlan | undefined,
  stdoutLength: number,
): boolean {
  if (!piece.source?.filePath) return false;
  if (!block) return false;

  if (block.location.kind === "whole-output") {
    return piece.start === 0 && piece.end === stdoutLength;
  }

  if (
    block.id === "sed-output" &&
    block.source?.commandName === "sed" &&
    block.location.kind === "from-cursor" &&
    block.location.end.kind === "end-of-output"
  ) {
    return piece.end === stdoutLength;
  }

  return false;
}

export function hasSemanticShellOutput(
  stdout: string,
  outputPlan: OutputPlan,
): boolean {
  return segmentOutput(stdout, outputPlan, { kind: "complete" }).pieces.some(
    (piece) => piece.kind === "structured",
  );
}

export function SemanticShellOutput({
  stdout,
  outputPlan,
}: {
  stdout: string;
  outputPlan: OutputPlan;
}): h.JSX.Element | null {
  const segmented = useMemo(
    () => segmentOutput(stdout, outputPlan, { kind: "complete" }),
    [stdout, outputPlan],
  );
  const hasStructured = segmented.pieces.some((p) => p.kind === "structured");
  const isSingleRawFull =
    segmented.pieces.length === 1 &&
    segmented.pieces[0]!.kind === "raw" &&
    segmented.pieces[0]!.start === 0 &&
    segmented.pieces[0]!.end === stdout.length;

  if (isSingleRawFull || !hasStructured) return null;

  const hasSearchBlock = outputPlan.blocks.some(
    (b) => b.source?.commandName === "rg",
  );
  const blockById = useMemo(() => {
    const map = new Map<string, OutputBlockPlan>();
    for (const block of outputPlan.blocks) map.set(block.id, block);
    return map;
  }, [outputPlan]);

  return (
    <div
      class="semantic-shell-output"
      data-testid={
        hasSearchBlock
          ? "semantic-shell-output-search"
          : "semantic-shell-output"
      }
    >
      <div class="semantic-shell-output-toolbar">
        <CopyButton text={segmented.copyText} />
      </div>
      {segmented.pieces.map((piece, i) => {
        const text = stdout.slice(piece.start, piece.end);
        if (piece.kind === "raw") {
          return (
            <pre key={i} class="tool-result semantic-shell-raw">
              {text}
            </pre>
          );
        }
        const block = blockById.get(piece.blockId);
        const allowFilePreview = canRenderStructuredFilePreview(
          piece,
          block,
          stdout.length,
        );
        return (
          <div
            key={`${piece.blockId}:${i}`}
            class="semantic-shell-structured-piece"
            data-testid={`semantic-shell-block-${piece.blockId}`}
          >
            <StructuredContent
              text={text}
              format={piece.format}
              sourceFilePath={piece.source?.filePath}
              allowFilePreview={allowFilePreview}
            />
          </div>
        );
      })}
    </div>
  );
}
