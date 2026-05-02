import { h, Fragment } from "preact";
import {
  projectSpan,
  type SourceNode,
  type SourceProjection,
} from "../lib/sourceTree";
import {
  buildSourceRenderPieces,
  type SourceRenderPiece,
} from "../lib/sourceTreeRenderPlan";
import { useHighlight, renderTokens } from "../highlight";
import { CodePre, CopyButton } from "./CopyButton";
import { Markdown } from "./Markdown";
import { FileContentPreview } from "./file-preview/FileContentPreview";

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

export function SourceTextSpanView({
  piece,
}: {
  piece: Extract<SourceRenderPiece, { kind: "inline" }>;
}) {
  const decodedTokens = useHighlight(
    piece.highlightText ?? piece.text,
    piece.language,
  );
  const rawTokens = useHighlight(piece.text, piece.language);

  let content: h.JSX.Element = (
    <>{rawTokens ? renderTokenLines(rawTokens) : piece.text}</>
  );

  if (piece.highlightText && piece.projection && decodedTokens) {
    const projected = renderProjectedTokenLines(
      piece.text,
      piece.projection,
      decodedTokens,
    );
    if (projected) content = projected;
  }

  if (!piece.projectedInline) return content;
  return (
    <span data-testid="source-projected-inline" data-language={piece.language}>
      {content}
    </span>
  );
}

export function SourceInlineEmbedView({
  piece,
}: {
  piece: Extract<SourceRenderPiece, { kind: "inline" }>;
}) {
  return <SourceTextSpanView piece={piece} />;
}

export function SourceRichEmbedView({
  piece,
  preClass,
  renderableFilePath,
}: {
  piece: Extract<SourceRenderPiece, { kind: "rich" }>;
  preClass: string;
  renderableFilePath?: string;
}) {
  const tokens = useHighlight(
    piece.mode === "rich-code" ? piece.text : null,
    piece.mode === "rich-code" ? piece.language : null,
  );

  if (piece.mode === "rich-markdown") {
    return <Markdown text={piece.text} class="text-content" />;
  }

  if (renderableFilePath) {
    return (
      <FileContentPreview
        filePath={renderableFilePath}
        content={piece.text}
        sourceContent={piece.sourceText}
        defaultSource={false}
      />
    );
  }

  return (
    <pre class={preClass}>{tokens ? renderTokenLines(tokens) : piece.text}</pre>
  );
}

type InlineBlock = {
  kind: "inline";
  id: string;
  pieces: Array<Extract<SourceRenderPiece, { kind: "inline" }>>;
};

type RichBlock = {
  kind: "rich";
  id: string;
  piece: Extract<SourceRenderPiece, { kind: "rich" }>;
};

type RenderBlock = InlineBlock | RichBlock;

function renderProjectedTokenLines(
  rawText: string,
  projection: SourceProjection,
  tokens: NonNullable<ReturnType<typeof useHighlight>>,
): h.JSX.Element | null {
  let decodedOffset = 0;
  const lines: h.JSX.Element[] = [];

  for (let lineIndex = 0; lineIndex < tokens.length; lineIndex++) {
    const line = tokens[lineIndex]!;
    const lineStart = decodedOffset;
    const lineLength = line.reduce(
      (sum, token) => sum + token.content.length,
      0,
    );
    const lineRawSpan = projectSpan(projection, {
      start: lineStart,
      end: lineStart + lineLength,
    });
    if (!lineRawSpan) return null;

    let tokenOffset = lineStart;
    let rawCursor = lineRawSpan.start;
    const lineParts: h.JSX.Element[] = [];

    for (let tokenIndex = 0; tokenIndex < line.length; tokenIndex++) {
      const token = line[tokenIndex]!;
      const tokenLength = token.content.length;
      const tokenRawSpan = projectSpan(projection, {
        start: tokenOffset,
        end: tokenOffset + tokenLength,
      });
      if (
        !tokenRawSpan ||
        tokenRawSpan.start < rawCursor ||
        tokenRawSpan.end < tokenRawSpan.start ||
        tokenRawSpan.end > lineRawSpan.end
      ) {
        return null;
      }

      if (tokenRawSpan.start > rawCursor) {
        lineParts.push(
          <Fragment key={`gap-${lineIndex}-${tokenIndex}`}>
            {rawText.slice(rawCursor, tokenRawSpan.start)}
          </Fragment>,
        );
      }

      const tokenRawText = rawText.slice(tokenRawSpan.start, tokenRawSpan.end);
      if (tokenRawText.length > 0) {
        lineParts.push(
          <span
            key={`token-${lineIndex}-${tokenIndex}`}
            style={token.color ? { color: token.color } : undefined}
          >
            {tokenRawText}
          </span>,
        );
      }

      rawCursor = tokenRawSpan.end;
      tokenOffset += tokenLength;
    }

    if (rawCursor < lineRawSpan.end) {
      lineParts.push(
        <Fragment key={`tail-${lineIndex}`}>
          {rawText.slice(rawCursor, lineRawSpan.end)}
        </Fragment>,
      );
    }

    lines.push(
      <Fragment key={lineIndex}>
        {lineIndex > 0 && "\n"}
        {lineParts}
      </Fragment>,
    );

    decodedOffset += lineLength;
    if (lineIndex + 1 < tokens.length) decodedOffset += 1;
  }

  return <Fragment>{lines}</Fragment>;
}

function toRenderBlocks(pieces: SourceRenderPiece[]): RenderBlock[] {
  const blocks: RenderBlock[] = [];
  let inline: Array<Extract<SourceRenderPiece, { kind: "inline" }>> = [];
  const flushInline = () => {
    if (inline.length === 0) return;
    blocks.push({
      kind: "inline",
      id: inline[0]!.id,
      pieces: inline,
    });
    inline = [];
  };
  for (const piece of pieces) {
    if (piece.kind === "inline") {
      inline.push(piece);
      continue;
    }
    flushInline();
    blocks.push({ kind: "rich", id: piece.id, piece });
  }
  flushInline();
  return blocks;
}

export function SourceNodeView({
  root,
  copyText,
  preClass = "write-content",
  renderableFilePath,
}: {
  root: SourceNode;
  copyText: string;
  preClass?: string;
  renderableFilePath?: string;
}) {
  const pieces = buildSourceRenderPieces(root);
  const blocks = toRenderBlocks(pieces);
  const hasRich = blocks.some((b) => b.kind === "rich");
  const onlyBlock = blocks.length === 1 ? blocks[0] : null;

  if (!hasRich && onlyBlock?.kind === "inline") {
    const inline = onlyBlock;
    return (
      <div data-testid="source-tree-input">
        <CodePre class={preClass} copyText={copyText}>
          {inline.pieces.map((piece) => (
            <SourceInlineEmbedView key={piece.id} piece={piece} />
          ))}
        </CodePre>
      </div>
    );
  }

  return (
    <div data-testid="source-tree-input" class="code-pre-wrap">
      <CopyButton text={copyText} />
      {blocks.map((block) =>
        block.kind === "inline" ? (
          <pre key={block.id} class={preClass}>
            {block.pieces.map((piece) => (
              <SourceInlineEmbedView key={piece.id} piece={piece} />
            ))}
          </pre>
        ) : (
          <SourceRichEmbedView
            key={block.id}
            piece={block.piece}
            preClass={preClass}
            renderableFilePath={renderableFilePath}
          />
        ),
      )}
    </div>
  );
}
