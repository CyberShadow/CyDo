export interface PatchHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];
}

export type ApplyPatchOperation = "add" | "update" | "delete";

export interface ApplyPatchSection {
  path: string;
  op: ApplyPatchOperation;
  patchText: string;
  addedContent?: string;
}

function normalizeDiffPath(path: string): string {
  if (path.startsWith("a/") || path.startsWith("b/")) return path.slice(2);
  return path;
}

function parseDiffHeaderPath(line: string, prefix: string): string | null {
  if (!line.startsWith(prefix)) return null;
  const rawValue = line.slice(prefix.length).trim();
  let value = rawValue.split("\t", 1)[0]?.trim() ?? "";
  const timestampSuffix = value.match(
    /^(.*)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s+[+-]\d{4})?$/,
  );
  if (timestampSuffix?.[1]) {
    value = timestampSuffix[1].trim();
  }
  if (!value || value === "/dev/null") return value;
  return normalizeDiffPath(value);
}

function parseRawDiffHeaderToken(line: string, prefix: string): string | null {
  if (!line.startsWith(prefix)) return null;
  const rawValue = line.slice(prefix.length).trim();
  const token = rawValue.split("\t", 1)[0]?.trim() ?? "";
  return token || null;
}

function isWhitespaceFreeToken(token: string): boolean {
  return !/\s/.test(token);
}

function isLikelyUnifiedHeaderPair(lines: string[], index: number): boolean {
  if (index + 1 >= lines.length) return false;
  const oldLine = lines[index]!;
  const newLine = lines[index + 1]!;
  if (
    parseDiffHeaderPath(oldLine, "--- ") == null ||
    parseDiffHeaderPath(newLine, "+++ ") == null
  ) {
    return false;
  }

  const oldToken = parseRawDiffHeaderToken(oldLine, "--- ");
  const newToken = parseRawDiffHeaderToken(newLine, "+++ ");
  if (oldToken == null || newToken == null) return false;

  const oldIsDevNull = oldToken === "/dev/null";
  const newIsDevNull = newToken === "/dev/null";
  const oldLooksLikeGitPath = oldIsDevNull || oldToken.startsWith("a/");
  const newLooksLikeGitPath = newIsDevNull || newToken.startsWith("b/");

  if (oldLooksLikeGitPath && newLooksLikeGitPath) return true;
  if (!isWhitespaceFreeToken(oldToken) || !isWhitespaceFreeToken(newToken)) {
    return false;
  }
  if (oldIsDevNull || newIsDevNull) return true;
  return oldToken === newToken;
}

export function parsePatchTextFromInput(
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

export function looksLikePatchText(text: string): boolean {
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
  const isUnifiedFileHeaderStart = (index: number): boolean => {
    const oldHeader = lines[index];
    return (
      oldHeader != null &&
      oldHeader.startsWith("--- ") &&
      isLikelyUnifiedHeaderPair(lines, index)
    );
  };
  const isBoundaryLine = (index: number): boolean => {
    const line = lines[index];
    if (line == null) return false;
    return (
      line.startsWith("@@") ||
      line.startsWith("*** End Patch") ||
      line.startsWith("*** Update File: ") ||
      line.startsWith("*** Add File: ") ||
      line.startsWith("*** Delete File: ") ||
      line.startsWith("diff --git ") ||
      line.startsWith("\\ No newline at end of file") ||
      isUnifiedFileHeaderStart(index)
    );
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (!line.startsWith("@@")) continue;
    const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
    let remainingOld = match ? (match[2] != null ? Number(match[2]) : 1) : null;
    let remainingNew = match ? (match[4] != null ? Number(match[4]) : 1) : null;

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
        current.startsWith("diff --git ")
      ) {
        break;
      }
      if (
        !match &&
        (current.startsWith("--- ") || current.startsWith("+++ "))
      ) {
        break;
      }
      if (current.startsWith("\\ No newline at end of file")) {
        i++;
        continue;
      }
      if (current === "" && i === lines.length - 1) {
        break;
      }

      const prefix = current[0];
      if (prefix === " " || prefix === "+" || prefix === "-") {
        hunkLines.push(current);
        if (remainingOld != null && remainingNew != null) {
          if (prefix === " " || prefix === "-") remainingOld--;
          if (prefix === " " || prefix === "+") remainingNew--;
        }
        i++;
        if (
          remainingOld != null &&
          remainingNew != null &&
          remainingOld <= 0 &&
          remainingNew <= 0
        ) {
          if (i < lines.length) {
            const isTrailingNewline = lines[i] === "" && i === lines.length - 1;
            if (!isTrailingNewline && !isBoundaryLine(i)) {
              sawMalformedLine = true;
            }
          }
          i--;
          break;
        }
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

function parseBeginPatchSections(patchText: string): ApplyPatchSection[] {
  const lines = patchText.split("\n");
  const sections: ApplyPatchSection[] = [];
  const isSectionStart = (line: string): boolean =>
    line.startsWith("*** Add File: ") ||
    line.startsWith("*** Update File: ") ||
    line.startsWith("*** Delete File: ");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (!isSectionStart(line)) continue;

    let op: ApplyPatchOperation | null = null;
    let rawPath = "";
    if (line.startsWith("*** Add File: ")) {
      op = "add";
      rawPath = line.slice("*** Add File: ".length).trim();
    } else if (line.startsWith("*** Update File: ")) {
      op = "update";
      rawPath = line.slice("*** Update File: ".length).trim();
    } else if (line.startsWith("*** Delete File: ")) {
      op = "delete";
      rawPath = line.slice("*** Delete File: ".length).trim();
    }
    const path = rawPath;
    if (!op || !path || path === "/dev/null") continue;

    const sectionLines = [line];
    const addedContentLines: string[] = [];

    while (i + 1 < lines.length) {
      const next = lines[i + 1]!;
      if (isSectionStart(next) || next.startsWith("*** End Patch")) break;
      i++;
      sectionLines.push(next);
      if (op === "add") {
        if (next.startsWith("+")) addedContentLines.push(next.slice(1));
        else if (next.startsWith(" ")) addedContentLines.push(next.slice(1));
      }
    }

    sections.push({
      path,
      op,
      patchText: sectionLines.join("\n"),
      addedContent: op === "add" ? addedContentLines.join("\n") : undefined,
    });
  }

  return sections;
}

function parseUnifiedDiffSections(patchText: string): ApplyPatchSection[] {
  const lines = patchText.split("\n");
  const sections: ApplyPatchSection[] = [];

  for (let i = 0; i < lines.length; i++) {
    const oldPath = parseDiffHeaderPath(lines[i]!, "--- ");
    if (oldPath == null) continue;
    if (i + 1 >= lines.length) continue;

    const next = lines[i + 1]!;
    const newPath = parseDiffHeaderPath(next, "+++ ");
    if (newPath == null) continue;

    const start = i;
    let end = i + 2;
    let remainingOld: number | null = null;
    let remainingNew: number | null = null;
    while (end < lines.length) {
      const line = lines[end]!;
      if (remainingOld != null && remainingNew != null) {
        if (line.startsWith("\\ No newline at end of file")) {
          end++;
          continue;
        }
        const prefix = line[0];
        if (prefix === " " || prefix === "+" || prefix === "-") {
          if (prefix === " " || prefix === "-") remainingOld--;
          if (prefix === " " || prefix === "+") remainingNew--;
          end++;
          if (remainingOld <= 0 && remainingNew <= 0) {
            remainingOld = null;
            remainingNew = null;
          }
          continue;
        }
        remainingOld = null;
        remainingNew = null;
      }
      if (line.startsWith("diff --git ")) break;
      if (line.startsWith("@@")) {
        const match = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
        if (match) {
          remainingOld = match[2] != null ? Number(match[2]) : 1;
          remainingNew = match[4] != null ? Number(match[4]) : 1;
        }
        end++;
        continue;
      }
      if (line.startsWith("--- ") && isLikelyUnifiedHeaderPair(lines, end)) {
        break;
      }
      end++;
    }
    i = end - 1;

    let op: ApplyPatchOperation | null = null;
    let path: string | null = null;
    if (newPath === "/dev/null") {
      if (oldPath && oldPath !== "/dev/null") {
        op = "delete";
        path = oldPath;
      }
    } else if (oldPath === "/dev/null") {
      if (newPath && newPath !== "/dev/null") {
        op = "add";
        path = newPath;
      }
    } else if (newPath && newPath !== "/dev/null") {
      op = "update";
      path = newPath;
    }
    if (!op || !path) continue;

    const sectionLines = lines.slice(start, end);
    let addedContent: string | undefined;
    if (op === "add") {
      const hunks = parsePatchHunksFromText(sectionLines.join("\n"));
      if (hunks?.length) {
        const newLines: string[] = [];
        for (const hunk of hunks) {
          for (const hunkLine of hunk.lines) {
            const prefix = hunkLine[0];
            if (prefix === " " || prefix === "+") {
              newLines.push(hunkLine.slice(1));
            }
          }
        }
        addedContent = newLines.join("\n");
      } else {
        const newLines: string[] = [];
        for (const line of sectionLines) {
          if (line.startsWith("+") && !line.startsWith("+++ ")) {
            newLines.push(line.slice(1));
          }
        }
        addedContent = newLines.join("\n");
      }
    }

    sections.push({
      path,
      op,
      patchText: sectionLines.join("\n"),
      addedContent,
    });
  }

  return sections;
}

export function parseApplyPatchSections(
  patchText: string,
): ApplyPatchSection[] {
  const beginPatchSections = parseBeginPatchSections(patchText);
  if (beginPatchSections.length > 0) return beginPatchSections;
  return parseUnifiedDiffSections(patchText);
}

export function toUnifiedPatch(patchText: string): string | null {
  const lines = patchText.split("\n");
  if (lines.length === 0) return null;
  const header = lines[0]!;
  if (!header.startsWith("*** Update File: ")) return null;
  const path = header.slice("*** Update File: ".length).trim();
  if (!path) return null;

  const hunks = parsePatchHunksFromText(patchText);
  if (hunks && hunks.length > 0) {
    const hunkParts = hunks.map(
      (h) =>
        `@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@\n${h.lines.join("\n")}`,
    );
    return `--- a/${path}\n+++ b/${path}\n${hunkParts.join("\n")}\n`;
  }

  const bodyLines: string[] = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i]!;
    if (
      line.startsWith("*** Begin Patch") ||
      line.startsWith("*** End Patch")
    ) {
      continue;
    }
    bodyLines.push(line);
  }
  const body = bodyLines.join("\n");
  return `--- a/${path}\n+++ b/${path}\n${body}\n`;
}
