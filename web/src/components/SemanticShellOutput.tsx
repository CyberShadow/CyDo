import { h, Fragment } from "preact";
import { useMemo } from "preact/hooks";
import { type ThemedToken, useHighlight, renderTokens } from "../highlight";
import { Markdown } from "./Markdown";
import { CodePre, CopyButton } from "./CopyButton";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";
import {
  segmentOutput,
  type OutputFormat,
  type OutputPlan,
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
}: {
  text: string;
  format: OutputFormat;
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
        return (
          <div
            key={`${piece.blockId}:${i}`}
            class="semantic-shell-structured-piece"
            data-testid={`semantic-shell-block-${piece.blockId}`}
          >
            <StructuredContent text={text} format={piece.format} />
          </div>
        );
      })}
    </div>
  );
}
