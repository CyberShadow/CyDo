import { h, Fragment } from "preact";
import { diffLines, diffWordsWithSpace, type Change } from "diff";
import type { ThemedToken } from "../../highlight";
import { useHighlight, langFromPath, renderTokens } from "../../highlight";
import type { PatchHunk } from "../../lib/patches";

interface AnnotatedSpan {
  content: string;
  color?: string;
  emphasized: boolean;
}

/** Split a diffLines change value into individual line strings. */
function splitChangeLines(value: string): string[] {
  const lines = value.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
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
  let tokenIndex = 0;
  let tokenOffset = 0;

  for (const change of relevant) {
    let remaining = change.value.length;
    const emphasized = side === "old" ? change.removed : change.added;

    while (remaining > 0 && tokenIndex < syntaxTokens.length) {
      const token = syntaxTokens[tokenIndex]!;
      const available = token.content.length - tokenOffset;
      const take = Math.min(remaining, available);

      result.push({
        content: token.content.slice(tokenOffset, tokenOffset + take),
        color: token.color,
        emphasized,
      });

      remaining -= take;
      tokenOffset += take;
      if (tokenOffset >= token.content.length) {
        tokenIndex++;
        tokenOffset = 0;
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
      {spans.map((span, index) => (
        <span
          key={index}
          class={
            span.emphasized
              ? side === "removed"
                ? "diff-word-removed"
                : "diff-word-added"
              : undefined
          }
          style={span.color ? { color: span.color } : undefined}
        >
          {span.content}
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
  for (const change of wordChanges) {
    if (!change.added && !change.removed) {
      commonLen += change.value.length;
      oldLen += change.value.length;
      newLen += change.value.length;
    } else if (change.removed) {
      oldLen += change.value.length;
    } else {
      newLen += change.value.length;
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
  let oldLineIndex = 0;
  let newLineIndex = 0;

  for (let changeIndex = 0; changeIndex < changes.length; changeIndex++) {
    const change = changes[changeIndex]!;
    const lines = splitChangeLines(change.value);

    if (!change.added && !change.removed) {
      for (let i = 0; i < lines.length; i++) {
        const lineIndex = oldLineIndex++;
        newLineIndex++;
        elements.push(
          <div key={`c${lineIndex}`} class="diff-context">
            {"  "}
            {oldTokens?.[lineIndex]
              ? renderTokens(oldTokens[lineIndex])
              : lines[i]}
          </div>,
        );
      }
    } else if (change.removed) {
      const next =
        changeIndex + 1 < changes.length ? changes[changeIndex + 1] : null;
      if (next?.added) {
        const addedLines = splitChangeLines(next.value);
        const pairCount = Math.min(lines.length, addedLines.length);

        const wordDiffs: { changes: Change[]; similar: boolean }[] = [];
        for (let i = 0; i < pairCount; i++) {
          const words = diffWordsWithSpace(lines[i]!, addedLines[i]!);
          wordDiffs.push({
            changes: words,
            similar: wordDiffSimilarity(words) >= WORD_DIFF_THRESHOLD,
          });
        }

        for (let i = 0; i < lines.length; i++) {
          const lineIndex = oldLineIndex + i;
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              oldTokens?.[lineIndex] ?? null,
              wordDiffs[i]!.changes,
              "old",
            );
            elements.push(
              <div key={`r${lineIndex}`} class="diff-removed">
                {"- "}
                {renderAnnotatedSpans(spans, "removed")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`r${lineIndex}`} class="diff-removed">
                {"- "}
                {oldTokens?.[lineIndex]
                  ? renderTokens(oldTokens[lineIndex])
                  : lines[i]}
              </div>,
            );
          }
        }

        for (let i = 0; i < addedLines.length; i++) {
          const lineIndex = newLineIndex + i;
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              newTokens?.[lineIndex] ?? null,
              wordDiffs[i]!.changes,
              "new",
            );
            elements.push(
              <div key={`a${lineIndex}`} class="diff-added">
                {"+ "}
                {renderAnnotatedSpans(spans, "added")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`a${lineIndex}`} class="diff-added">
                {"+ "}
                {newTokens?.[lineIndex]
                  ? renderTokens(newTokens[lineIndex])
                  : addedLines[i]}
              </div>,
            );
          }
        }

        oldLineIndex += lines.length;
        newLineIndex += addedLines.length;
        changeIndex++;
      } else {
        for (let i = 0; i < lines.length; i++) {
          const lineIndex = oldLineIndex++;
          elements.push(
            <div key={`r${lineIndex}`} class="diff-removed">
              {"- "}
              {oldTokens?.[lineIndex]
                ? renderTokens(oldTokens[lineIndex])
                : lines[i]}
            </div>,
          );
        }
      }
    } else {
      for (let i = 0; i < lines.length; i++) {
        const lineIndex = newLineIndex++;
        elements.push(
          <div key={`a${lineIndex}`} class="diff-added">
            {"+ "}
            {newTokens?.[lineIndex]
              ? renderTokens(newTokens[lineIndex])
              : lines[i]}
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

export function PatchView({
  hunks,
  filePath,
}: {
  hunks: PatchHunk[];
  filePath?: string;
}) {
  const lang = filePath ? langFromPath(filePath) : null;

  let maxLineNum = 0;
  for (const hunk of hunks) {
    maxLineNum = Math.max(
      maxLineNum,
      hunk.oldStart + hunk.oldLines,
      hunk.newStart + hunk.newLines,
    );
  }
  const gutterWidth = `${String(maxLineNum).length}ch`;

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

  const oldTokens = useHighlight(oldLinesList.join("\n"), lang);
  const newTokens = useHighlight(newLinesList.join("\n"), lang);

  const elements: h.JSX.Element[] = [];
  let rowKey = 0;
  let oldTokenIndex = 0;
  let newTokenIndex = 0;

  for (let hunkIndex = 0; hunkIndex < hunks.length; hunkIndex++) {
    const hunk = hunks[hunkIndex]!;
    const keyPrefix = `h${hunkIndex}`;
    elements.push(
      <div key={`${keyPrefix}-${rowKey++}`} class="diff-header">
        @@ -{hunk.oldStart},{hunk.oldLines} +{hunk.newStart},{hunk.newLines} @@
      </div>,
    );

    let oldLineNum = hunk.oldStart;
    let newLineNum = hunk.newStart;
    let lineIndex = 0;

    while (lineIndex < hunk.lines.length) {
      const line = hunk.lines[lineIndex]!;
      const prefix = line[0];
      if (prefix === " ") {
        const content = line.slice(1);
        const oldIndex = oldTokenIndex++;
        newTokenIndex++;
        const oldNum = oldLineNum++;
        const newNum = newLineNum++;
        elements.push(
          <div key={`${keyPrefix}-${rowKey++}`} class="diff-context">
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {oldNum}
            </span>
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {newNum}
            </span>
            {"  "}
            {oldTokens?.[oldIndex]
              ? renderTokens(oldTokens[oldIndex])
              : content}
          </div>,
        );
        lineIndex++;
      } else if (prefix === "-") {
        const removeStart = lineIndex;
        while (
          lineIndex < hunk.lines.length &&
          hunk.lines[lineIndex]![0] === "-"
        ) {
          lineIndex++;
        }
        const removedContents = hunk.lines
          .slice(removeStart, lineIndex)
          .map((item) => item.slice(1));

        const addStart = lineIndex;
        while (
          lineIndex < hunk.lines.length &&
          hunk.lines[lineIndex]![0] === "+"
        ) {
          lineIndex++;
        }
        const addedContents = hunk.lines
          .slice(addStart, lineIndex)
          .map((item) => item.slice(1));

        const pairCount = Math.min(
          removedContents.length,
          addedContents.length,
        );
        const wordDiffs: { changes: Change[]; similar: boolean }[] = [];
        for (let i = 0; i < pairCount; i++) {
          const words = diffWordsWithSpace(
            removedContents[i]!,
            addedContents[i]!,
          );
          wordDiffs.push({
            changes: words,
            similar: wordDiffSimilarity(words) >= WORD_DIFF_THRESHOLD,
          });
        }

        for (let i = 0; i < removedContents.length; i++) {
          const oldIndex = oldTokenIndex++;
          const oldNum = oldLineNum++;
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              oldTokens?.[oldIndex] ?? null,
              wordDiffs[i]!.changes,
              "old",
            );
            elements.push(
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-removed">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {oldNum}
                </span>
                <span class="diff-gutter" style={{ minWidth: gutterWidth }} />
                {"- "}
                {renderAnnotatedSpans(spans, "removed")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-removed">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {oldNum}
                </span>
                <span class="diff-gutter" style={{ minWidth: gutterWidth }} />
                {"- "}
                {oldTokens?.[oldIndex]
                  ? renderTokens(oldTokens[oldIndex])
                  : removedContents[i]}
              </div>,
            );
          }
        }

        for (let i = 0; i < addedContents.length; i++) {
          const newIndex = newTokenIndex++;
          const newNum = newLineNum++;
          if (i < pairCount && wordDiffs[i]!.similar) {
            const spans = overlayDiff(
              newTokens?.[newIndex] ?? null,
              wordDiffs[i]!.changes,
              "new",
            );
            elements.push(
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }} />
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {newNum}
                </span>
                {"+ "}
                {renderAnnotatedSpans(spans, "added")}
              </div>,
            );
          } else {
            elements.push(
              <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
                <span class="diff-gutter" style={{ minWidth: gutterWidth }} />
                <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
                  {newNum}
                </span>
                {"+ "}
                {newTokens?.[newIndex]
                  ? renderTokens(newTokens[newIndex])
                  : addedContents[i]}
              </div>,
            );
          }
        }
      } else if (prefix === "+") {
        const content = line.slice(1);
        const newIndex = newTokenIndex++;
        const newNum = newLineNum++;
        elements.push(
          <div key={`${keyPrefix}-${rowKey++}`} class="diff-added">
            <span class="diff-gutter" style={{ minWidth: gutterWidth }} />
            <span class="diff-gutter" style={{ minWidth: gutterWidth }}>
              {newNum}
            </span>
            {"+ "}
            {newTokens?.[newIndex]
              ? renderTokens(newTokens[newIndex])
              : content}
          </div>,
        );
        lineIndex++;
      } else {
        lineIndex++;
      }
    }
  }

  return <div class="diff-view">{elements}</div>;
}
