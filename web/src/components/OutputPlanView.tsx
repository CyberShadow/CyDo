import { h, Fragment } from "preact";
import { useMemo } from "preact/hooks";
import {
  useHighlight,
  useHighlightRows,
  renderHighlightedSource,
  renderHighlightedRow,
} from "../highlight";
import { LocalFileDocument } from "./LocalFileContext";
import { Markdown } from "./Markdown";
import { CodePre, CopyButton } from "./CopyButton";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";
import { FileContentPreview } from "./file-preview/FileContentPreview";
import { detectRenderableFormat } from "../lib/fileFormats";
import {
  parseNlOutputRows,
  splitNlRuns,
  parseNumberedOutputRow,
  segmentOutput,
  splitOutputRows,
  type OutputFormat,
  type OutputPlan,
  type OutputBlockPlan,
} from "../lib/outputPlan";

function outputCodeLanguage(language: string): string | null {
  return language === "text" ||
    language === "shell-output" ||
    language === "markdown"
    ? null
    : language;
}

function NlNumberedRows({
  text,
  format,
  linePrefixTestId,
}: {
  text: string;
  format: Extract<OutputFormat, { kind: "nl-line-number-prefixed" }>;
  linePrefixTestId?: string;
}): h.JSX.Element {
  const rows = Array.from(
    parseNlOutputRows(text, format),
    ({ row, terminator }) => {
      if (!row) throw new Error("invalid row in structured nl output");
      return { ...row, terminator };
    },
  );
  const tokens = useHighlightRows(
    rows.map((row) => row.text),
    outputCodeLanguage(format.format.language),
  );
  return (
    <>
      {rows.map(({ prefix, text: rowText, terminator }, i) => {
        return (
          <Fragment key={i}>
            <span
              class="line-number"
              data-testid={linePrefixTestId ?? "output-line-prefix"}
            >
              {prefix}
            </span>
            {renderHighlightedRow(tokens, i, rowText)}
            {terminator}
          </Fragment>
        );
      })}
    </>
  );
}

function HighlightedInlineRow({
  text,
  language,
}: {
  text: string;
  language: string;
}): h.JSX.Element {
  const tokens = useHighlightRows([text], outputCodeLanguage(language));
  return <>{renderHighlightedRow(tokens, 0, text)}</>;
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
  if (format.kind === "content") {
    return (
      <HighlightedInlineRow key={text} text={text} language={format.language} />
    );
  }

  if (format.kind === "line-number-prefixed") {
    return (
      <>
        {Array.from(splitOutputRows(text), ({ text: line, terminator }, i) => {
          const row = parseNumberedOutputRow(line);
          if (!row) {
            return (
              <Fragment key={i}>
                <InlineFormatted text={line} format={format.format} />
                {terminator}
              </Fragment>
            );
          }
          if (row.kind === "group-separator") {
            return (
              <Fragment key={i}>
                <span class="search-group-separator">--</span>
                {terminator}
              </Fragment>
            );
          }
          return (
            <Fragment key={i}>
              <span
                class="line-number"
                data-testid={linePrefixTestId ?? "output-line-prefix"}
              >
                {row.prefix}
              </span>
              <InlineFormatted
                text={row.text}
                format={format.format}
                linePrefixTestId={linePrefixTestId}
              />
              {terminator}
            </Fragment>
          );
        })}
      </>
    );
  }

  switch (format.kind) {
    case "nl-line-number-prefixed":
      return (
        <NlNumberedRows
          text={text}
          format={format}
          linePrefixTestId={linePrefixTestId}
        />
      );
    case "nl-runs": {
      const spans = splitNlRuns(text, format);
      if (!spans) throw new Error("invalid runs in structured nl output");
      return (
        <>
          {spans.map(({ start, end }, index) => (
            <NlNumberedRows
              key={start}
              text={text.slice(start, end)}
              format={{
                kind: "nl-line-number-prefixed",
                width: format.width,
                separator: format.separator,
                format: format.runs[index]!,
              }}
              linePrefixTestId={linePrefixTestId}
            />
          ))}
        </>
      );
    }
    case "individual-lines": {
      return (
        <>
          {Array.from(
            splitOutputRows(text),
            ({ text: line, terminator }, i) => (
              <Fragment key={i}>
                <InlineFormatted
                  text={line}
                  format={format.format}
                  linePrefixTestId={linePrefixTestId}
                />
                {terminator}
              </Fragment>
            ),
          )}
        </>
      );
    }
  }

  const unexpectedFormat: never = format;
  throw new Error(`unexpected output format: ${String(unexpectedFormat)}`);
}

function StructuredContent({
  text,
  format,
  document,
  linePrefixTestId,
}: {
  text: string;
  format: OutputFormat;
  document?: OutputBlockPlan["document"];
  linePrefixTestId?: string;
}): h.JSX.Element {
  const codeLanguage =
    format.kind === "content" ? outputCodeLanguage(format.language) : null;
  const highlightedCode = useHighlight(
    codeLanguage ? text : null,
    codeLanguage,
  );

  if (format.kind === "content") {
    if (
      document?.preview &&
      detectRenderableFormat(document.filePath, text) != null
    ) {
      return <FileContentPreview filePath={document.filePath} content={text} />;
    }

    if (document && format.language === "markdown") {
      return (
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={
            <CodePre class="tool-result" copyText={text}>
              {text}
            </CodePre>
          }
          renderedView={
            <LocalFileDocument filePath={document.filePath}>
              <Markdown
                text={text}
                class="text-content"
                enableSourceToggle={false}
              />
            </LocalFileDocument>
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
        {renderHighlightedSource(text, highlightedCode)}
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
        if (!block) throw new Error(`Missing output block ${piece.blockId}`);
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
              document={block.document}
              linePrefixTestId={linePrefixTestId}
            />
          </div>
        );
      })}
    </div>
  );
}
