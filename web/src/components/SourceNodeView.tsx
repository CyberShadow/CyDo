import { h } from "preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import type { SourceNode } from "../lib/sourceTree";
import {
  buildSourceRenderPieces,
  type SourceRenderPiece,
} from "../lib/sourceTreeRenderPlan";
import {
  highlightedSourceRows,
  tokenize,
  useHighlight,
  renderHighlightedSource,
  type ThemedToken,
} from "../highlight";
import { useCurrentTheme } from "../useTheme";
import { CodePre, CopyButton } from "./CopyButton";
import { LocalFileDocument } from "./LocalFileContext";
import { Markdown } from "./Markdown";
import { ApplyPatchChanges } from "./FileChangeRow";
import { FileContentPreview } from "./file-preview/FileContentPreview";
import { SourceRenderedToggle } from "./file-preview/SourceRenderedToggle";

type InlinePiece = Extract<SourceRenderPiece, { kind: "inline" }>;

function useInlineHighlights(pieces: SourceRenderPiece[]) {
  const sources = useMemo(
    () => [
      ...new Set(
        pieces.flatMap((piece) =>
          piece.kind === "inline" ? [piece.highlightSource] : [],
        ),
      ),
    ],
    [pieces],
  );
  const theme = useCurrentTheme() === "light" ? "github-light" : "github-dark";
  const [highlighted, setHighlighted] = useState<{
    sources: SourceNode[];
    theme: typeof theme;
    tokens: ReadonlyMap<SourceNode, ThemedToken[] | null>;
  } | null>(null);

  useEffect(() => {
    if (sources.length === 0) return;
    let active = true;
    void Promise.all(
      sources.map(async (source) => {
        const tokens = await tokenize(source.text, source.language, theme);
        if (tokens !== null) highlightedSourceRows(source.text, tokens);
        return [source, tokens?.flat() ?? null] as const;
      }),
    ).then((entries) => {
      if (active) setHighlighted({ sources, theme, tokens: new Map(entries) });
    });
    return () => {
      active = false;
    };
  }, [sources, theme]);

  return highlighted?.sources === sources && highlighted.theme === theme
    ? highlighted.tokens
    : null;
}

function renderInlineTokens(piece: InlinePiece, tokens: ThemedToken[]) {
  const { start, end } = piece.highlightSpan;
  // A raw fragment can survive when its parent span cannot be projected.
  if (
    !piece.projection &&
    piece.text !== piece.highlightSource.text.slice(start, end)
  )
    return piece.text;
  let first = 0;
  let last = tokens.length;
  while (first < last) {
    const middle = Math.floor((first + last) / 2);
    const token = tokens[middle]!;
    if (token.offset + token.content.length <= start) first = middle + 1;
    else last = middle;
  }

  const parts: (string | h.JSX.Element)[] = [];
  let cursor = 0;
  const project = piece.projection?.();
  for (let index = first; index < tokens.length; index++) {
    const token = tokens[index]!;
    if (token.offset >= end) break;
    const local = {
      start: Math.max(start, token.offset) - start,
      end: Math.min(end, token.offset + token.content.length) - start,
    };
    const rawStart = project ? project(local.start) : local.start;
    const rawEnd = project ? project(local.end) : local.end;
    if (rawStart === null || rawEnd === null) return piece.text;
    const raw = { start: rawStart, end: rawEnd };
    if (raw.start > cursor) parts.push(piece.text.slice(cursor, raw.start));
    if (raw.end > raw.start) {
      parts.push(
        <span
          key={index}
          style={token.color ? { color: token.color } : undefined}
        >
          {piece.text.slice(raw.start, raw.end)}
        </span>,
      );
    }
    cursor = raw.end;
  }
  parts.push(piece.text.slice(cursor));
  return parts;
}

function SourceInlineEmbedView({
  piece,
  tokens,
}: {
  piece: InlinePiece;
  tokens: ThemedToken[] | null | undefined;
}) {
  const content = tokens ? renderInlineTokens(piece, tokens) : piece.text;
  if (!piece.projectedInline) return <>{content}</>;
  return (
    <span data-testid="source-projected-inline" data-language={piece.language}>
      {content}
    </span>
  );
}

function SourceRichEmbedView({
  piece,
  preClass,
  blockClass,
}: {
  piece: Extract<SourceRenderPiece, { kind: "rich" }>;
  preClass: string;
  blockClass?: string;
}) {
  const tokens = useHighlight(
    piece.mode === "rich-code" ? piece.text : null,
    piece.mode === "rich-code" ? piece.language : null,
  );
  const sourceTokens = useHighlight(
    piece.mode === "rich-markdown" ? piece.sourceText : null,
    piece.mode === "rich-markdown" ? "markdown" : null,
  );
  const blockClassName = blockClass ? ` ${blockClass}` : "";

  if (piece.mode === "rich-markdown") {
    const markdown = (
      <Markdown
        text={piece.text}
        class="text-content"
        enableSourceToggle={false}
      />
    );
    return (
      <div class={`source-tree-rich-block${blockClassName}`}>
        <SourceRenderedToggle
          defaultSource={false}
          sourceView={
            <CodePre class={preClass} copyText={piece.sourceText}>
              {renderHighlightedSource(piece.sourceText, sourceTokens)}
            </CodePre>
          }
          renderedView={
            piece.document ? (
              <LocalFileDocument filePath={piece.document.filePath}>
                {markdown}
              </LocalFileDocument>
            ) : (
              markdown
            )
          }
        />
      </div>
    );
  }

  if (piece.mode === "rich-patch") {
    return (
      <div class={`source-tree-rich-block${blockClassName}`}>
        <ApplyPatchChanges patchText={piece.text} alwaysShowMeta />
      </div>
    );
  }

  if (piece.document) {
    return (
      <div class={`source-tree-rich-block${blockClassName}`}>
        <FileContentPreview
          filePath={piece.document.filePath}
          content={piece.text}
          sourceContent={piece.sourceText}
          defaultSource={false}
        />
      </div>
    );
  }

  return (
    <pre class={`${preClass}${blockClassName}`}>
      {renderHighlightedSource(piece.text, tokens)}
    </pre>
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

function sourceTreeBlockClass(index: number, count: number): string {
  const classes = ["source-tree-block"];
  if (index === 0) classes.push("source-tree-block-start");
  if (index === count - 1) classes.push("source-tree-block-end");
  return classes.join(" ");
}

export function SourceNodeView({
  root,
  copyText,
  preClass = "write-content",
}: {
  root: SourceNode;
  copyText: string;
  preClass?: string;
}) {
  const pieces = useMemo(() => buildSourceRenderPieces(root), [root]);
  const inlineHighlights = useInlineHighlights(pieces);
  const blocks = toRenderBlocks(pieces);

  return (
    <div
      data-testid="source-tree-input"
      class="code-pre-wrap source-tree-blocks"
    >
      <CopyButton text={copyText} />
      {blocks.map((block, index) => {
        const blockClass = sourceTreeBlockClass(index, blocks.length);
        return block.kind === "inline" ? (
          <pre key={block.id} class={`${preClass} ${blockClass}`}>
            {block.pieces.map((piece) => (
              <SourceInlineEmbedView
                key={piece.id}
                piece={piece}
                tokens={inlineHighlights?.get(piece.highlightSource)}
              />
            ))}
          </pre>
        ) : (
          <SourceRichEmbedView
            key={block.id}
            piece={block.piece}
            preClass={preClass}
            blockClass={blockClass}
          />
        );
      })}
    </div>
  );
}
