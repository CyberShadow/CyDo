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
} from "../lib/outputPlan";

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
  linePrefixTestId,
}: {
  text: string;
  format: OutputFormat;
  linePrefixTestId?: string;
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
                data-testid={linePrefixTestId ?? "output-line-prefix"}
              >
                {prefix}
              </span>
              <InlineFormatted
                text={suffix}
                format={format.format}
                linePrefixTestId={linePrefixTestId}
              />
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
        <InlineFormatted
          key={i}
          text={line}
          format={format.format}
          linePrefixTestId={linePrefixTestId}
        />
      ))}
    </>
  );
}

function StructuredContent({
  text,
  format,
  sourceFilePath,
  allowFilePreview,
  linePrefixTestId,
}: {
  text: string;
  format: OutputFormat;
  sourceFilePath?: string;
  allowFilePreview: boolean;
  linePrefixTestId?: string;
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
          renderedView={
            <Markdown
              text={text}
              class="text-content"
              enableSourceToggle={false}
            />
          }
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
      <InlineFormatted
        text={text}
        format={format}
        linePrefixTestId={linePrefixTestId}
      />
    </CodePre>
  );
}

export function hasStructuredOutput(
  stdout: string,
  outputPlan: OutputPlan,
): boolean {
  return segmentOutput(stdout, outputPlan, { kind: "complete" }).pieces.some(
    (piece) => piece.kind === "structured",
  );
}

export function OutputPlanView({
  stdout,
  outputPlan,
  className,
  testId,
  blockTestIdPrefix,
  toolbarClassName,
  rawClassName,
  structuredPieceClassName,
  linePrefixTestId,
  canRenderFilePreview,
}: {
  stdout: string;
  outputPlan: OutputPlan;
  className?: string;
  testId?: string;
  blockTestIdPrefix?: string;
  toolbarClassName?: string;
  rawClassName?: string;
  structuredPieceClassName?: string;
  linePrefixTestId?: string;
  canRenderFilePreview?: (args: {
    piece: Extract<SegmentedOutputPiece, { kind: "structured" }>;
    block?: OutputBlockPlan;
    stdoutLength: number;
  }) => boolean;
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
  const blockById = useMemo(() => {
    const map = new Map<string, OutputBlockPlan>();
    for (const block of outputPlan.blocks) map.set(block.id, block);
    return map;
  }, [outputPlan]);

  if (isSingleRawFull || !hasStructured) return null;

  return (
    <div class={className} data-testid={testId}>
      <div class={toolbarClassName ?? "output-plan-toolbar"}>
        <CopyButton text={segmented.copyText} />
      </div>
      {segmented.pieces.map((piece, i) => {
        const text = stdout.slice(piece.start, piece.end);
        if (piece.kind === "raw") {
          return (
            <pre key={i} class={rawClassName ?? "tool-result output-plan-raw"}>
              {text}
            </pre>
          );
        }
        const block = blockById.get(piece.blockId);
        const allowFilePreview =
          canRenderFilePreview?.({
            piece,
            block,
            stdoutLength: stdout.length,
          }) ?? false;
        return (
          <div
            key={`${piece.blockId}:${i}`}
            class={structuredPieceClassName ?? "output-plan-structured-piece"}
            data-testid={
              blockTestIdPrefix
                ? `${blockTestIdPrefix}${piece.blockId}`
                : undefined
            }
          >
            <StructuredContent
              text={text}
              format={piece.format}
              sourceFilePath={piece.source?.filePath}
              allowFilePreview={allowFilePreview}
              linePrefixTestId={linePrefixTestId}
            />
          </div>
        );
      })}
    </div>
  );
}
