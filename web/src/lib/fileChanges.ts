import type { FileChangePayload, FileEditOp } from "../types";
import {
  looksLikePatchText,
  parseApplyPatchSections,
  parsePatchHunksFromText,
  parsePatchTextFromInput,
  type PatchHunk,
} from "./patches";

export type NormalizedFileOperation =
  | "add"
  | "update"
  | "delete"
  | "edit"
  | "write"
  | "other";

export interface NormalizedFileChange {
  path: string | null;
  op: NormalizedFileOperation;
  label: string;
  oldText?: string;
  newText?: string;
  content?: string;
  patchText?: string;
  patchHunks?: PatchHunk[];
  raw: unknown;
}

function parseFileChangeOperation(
  kind: unknown,
  op: unknown,
  diffText: string | null,
): {
  label: string;
  type: "add" | "update" | "delete" | "other";
} {
  const opType = typeof op === "string" ? op : null;
  const kindType =
    kind &&
    typeof kind === "object" &&
    !Array.isArray(kind) &&
    typeof (kind as Record<string, unknown>).type === "string"
      ? ((kind as Record<string, unknown>).type as string)
      : typeof kind === "string"
        ? kind
        : null;
  const normalized = (kindType ?? opType)?.trim().toLowerCase();

  if (normalized === "add" || normalized === "create" || normalized === "new") {
    return { label: "Add", type: "add" };
  }
  if (
    normalized === "update" ||
    normalized === "patch" ||
    normalized === "modify" ||
    normalized === "edit"
  ) {
    return { label: "Patch", type: "update" };
  }
  if (normalized === "delete" || normalized === "remove") {
    return { label: "Delete", type: "delete" };
  }

  if (diffText && looksLikePatchText(diffText)) {
    return { label: "Patch", type: "update" };
  }
  if (normalized && normalized.length > 0) {
    const label = normalized[0]!.toUpperCase() + normalized.slice(1);
    return { label, type: "other" };
  }
  return { label: "Change", type: "other" };
}

export function parseCodexFileChanges(input: Record<string, unknown>): {
  changes: NormalizedFileChange[];
  unparsed: unknown[];
} {
  if (!Array.isArray(input.changes)) return { changes: [], unparsed: [] };

  const changes: NormalizedFileChange[] = [];
  const unparsed: unknown[] = [];

  for (const rawChange of input.changes) {
    if (
      !rawChange ||
      typeof rawChange !== "object" ||
      Array.isArray(rawChange)
    ) {
      unparsed.push(rawChange);
      continue;
    }
    const change = rawChange as Record<string, unknown>;
    const path =
      typeof change.path === "string"
        ? change.path
        : typeof change.file_path === "string"
          ? change.file_path
          : null;
    const diffText = typeof change.diff === "string" ? change.diff : null;
    const patchText =
      typeof change.patchText === "string" ? change.patchText : null;
    const contentText =
      typeof change.content === "string" ? change.content : null;
    const oldString =
      typeof change.old_string === "string"
        ? change.old_string
        : typeof change.oldString === "string"
          ? change.oldString
          : null;
    const newString =
      typeof change.new_string === "string"
        ? change.new_string
        : typeof change.newString === "string"
          ? change.newString
          : null;
    const hasOperation =
      typeof change.op === "string" ||
      typeof change.kind === "string" ||
      (change.kind &&
        typeof change.kind === "object" &&
        !Array.isArray(change.kind) &&
        typeof (change.kind as Record<string, unknown>).type === "string");
    const hasBodyLike =
      typeof diffText === "string" ||
      typeof patchText === "string" ||
      typeof contentText === "string" ||
      typeof oldString === "string" ||
      typeof newString === "string";

    if (!path && !hasOperation && !hasBodyLike) {
      unparsed.push(rawChange);
      continue;
    }

    const bodyText = diffText ?? patchText ?? contentText;
    const body = typeof bodyText === "string" ? bodyText : null;
    const operation = parseFileChangeOperation(
      change.kind,
      change.op,
      bodyText,
    );

    if (operation.type === "add") {
      const newText = newString ?? contentText ?? diffText ?? patchText ?? "";
      changes.push({
        path,
        op: "add",
        label: operation.label,
        oldText: "",
        newText,
        content: newText,
        raw: rawChange,
      });
      continue;
    }

    if (operation.type === "delete") {
      const oldText = oldString ?? diffText ?? contentText ?? patchText ?? "";
      changes.push({
        path,
        op: "delete",
        label: operation.label,
        oldText,
        newText: "",
        content: oldText,
        raw: rawChange,
      });
      continue;
    }

    if (typeof oldString === "string" && typeof newString === "string") {
      changes.push({
        path,
        op: operation.type === "update" ? "update" : "other",
        label: operation.label,
        oldText: oldString,
        newText: newString,
        raw: rawChange,
      });
      continue;
    }

    if (body && looksLikePatchText(body)) {
      changes.push({
        path,
        op: operation.type === "update" ? "update" : "other",
        label: operation.label,
        patchText: body,
        patchHunks: parsePatchHunksFromText(body) ?? undefined,
        raw: rawChange,
      });
      continue;
    }

    if (body) {
      changes.push({
        path,
        op: operation.type === "update" ? "update" : "other",
        label: operation.label,
        content: body,
        raw: rawChange,
      });
      continue;
    }

    unparsed.push(rawChange);
  }

  return { changes, unparsed };
}

export function getApplyPatchFileChanges(
  input: Record<string, unknown>,
): NormalizedFileChange[] {
  const patchText = parsePatchTextFromInput(input);
  if (!patchText) return [];

  return parseApplyPatchSections(patchText).map((section) => ({
    path: section.path,
    op: section.op,
    label:
      section.op === "add"
        ? "Add"
        : section.op === "delete"
          ? "Delete"
          : "Patch",
    content:
      section.op === "add"
        ? (section.addedContent ?? "")
        : section.op === "delete"
          ? ""
          : undefined,
    patchText: section.patchText,
    patchHunks:
      section.op === "update"
        ? (parsePatchHunksFromText(section.patchText) ?? undefined)
        : undefined,
    raw: section,
  }));
}

export function getNormalizedFilePaths(
  changes: NormalizedFileChange[],
): string[] {
  const paths: string[] = [];
  const seen = new Set<string>();
  for (const change of changes) {
    const path = change.path;
    if (!path || seen.has(path)) continue;
    seen.add(path);
    paths.push(path);
  }
  return paths;
}

export function fileEditPayloadFromNormalizedChange(
  change: NormalizedFileChange,
): FileChangePayload {
  if (change.op === "update") {
    if (typeof change.patchText === "string") {
      return { mode: "patch_text", patchText: change.patchText };
    }
    if (typeof change.content === "string") {
      return { mode: "full_content", content: change.content };
    }
    return { mode: "none" };
  }

  if (change.op === "add") {
    if (typeof change.newText === "string") {
      return { mode: "full_content", content: change.newText };
    }
    if (typeof change.content === "string") {
      return { mode: "full_content", content: change.content };
    }
    return { mode: "none" };
  }

  if (change.op === "delete") {
    if (typeof change.oldText === "string") {
      return { mode: "full_content", content: change.oldText };
    }
    if (typeof change.content === "string") {
      return { mode: "full_content", content: change.content };
    }
    return { mode: "none" };
  }

  if (typeof change.patchText === "string") {
    return { mode: "patch_text", patchText: change.patchText };
  }
  if (typeof change.content === "string") {
    return { mode: "full_content", content: change.content };
  }
  return { mode: "none" };
}

export function toFileEditOperation(
  op: NormalizedFileOperation,
): FileEditOp | null {
  if (
    op === "add" ||
    op === "update" ||
    op === "delete" ||
    op === "edit" ||
    op === "write"
  ) {
    return op;
  }
  return null;
}
