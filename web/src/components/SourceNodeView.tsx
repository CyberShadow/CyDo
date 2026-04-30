import { h, Fragment } from "preact";
import type { SourceNode } from "../lib/sourceTree";
import {
  buildSourceRenderPieces,
  type SourceRenderPiece,
} from "../lib/sourceTreeRenderPlan";
import { useHighlight, renderTokens } from "../highlight";
import { CodePre, CopyButton } from "./CopyButton";
import { Markdown } from "./Markdown";

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
  text,
  language,
  wrapperPayload,
}: {
  text: string;
  language: string;
  wrapperPayload: boolean;
}) {
  const tokens = useHighlight(text, language);
  if (wrapperPayload) {
    return (
      <span data-testid="semantic-shell-wrapper-payload" data-language="bash">
        {tokens ? renderTokenLines(tokens) : text}
      </span>
    );
  }
  return <>{tokens ? renderTokenLines(tokens) : text}</>;
}

export function SourceInlineEmbedView({
  piece,
}: {
  piece: Extract<SourceRenderPiece, { kind: "inline" }>;
}) {
  return (
    <SourceTextSpanView
      text={piece.text}
      language={piece.language}
      wrapperPayload={piece.wrapperPayload}
    />
  );
}

export function SourceRichEmbedView({
  piece,
  preClass,
}: {
  piece: Extract<SourceRenderPiece, { kind: "rich" }>;
  preClass: string;
}) {
  const tokens = useHighlight(
    piece.mode === "rich-code" ? piece.text : null,
    piece.mode === "rich-code" ? piece.language : null,
  );

  if (piece.mode === "rich-markdown") {
    return <Markdown text={piece.text} class="text-content" />;
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
}: {
  root: SourceNode;
  copyText: string;
  preClass?: string;
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
          />
        ),
      )}
    </div>
  );
}
