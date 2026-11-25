import type { FlowSink } from "./contentFlow";
import {
  assertValidParsedShellDocument,
  type ParsedShellCommand,
  type ParsedShellCommandId,
  type ParsedShellDocument,
  type ParsedShellRedirect,
} from "./shellParser";

export type ShellFdBinding =
  | FlowSink
  | { kind: "source"; redirectId: number }
  | { kind: "inherited-stdin" };

const unknown = { kind: "unknown" } as const;
const toolOutput = { kind: "tool-output" } as const;

const maxDescriptor = 2147483647;

function overflowPrefix({ descriptor }: ParsedShellRedirect) {
  return descriptor !== null && Number(descriptor.value) > maxDescriptor
    ? descriptor
    : null;
}

export function shellArgumentWords(
  args: ParsedShellCommand["arguments"],
  redirects: readonly ParsedShellRedirect[],
) {
  const words = args.map(({ word }) => word);
  const prefixes = redirects.flatMap((redirect) => {
    const prefix = overflowPrefix(redirect);
    return prefix === null
      ? []
      : [
          {
            kind: "literal" as const,
            value: prefix.value,
            rawSpan: prefix.rawSpan,
          },
        ];
  });
  return prefixes.length === 0
    ? words
    : [...words, ...prefixes].sort((a, b) => a.rawSpan.start - b.rawSpan.start);
}

function describeRedirect(redirect: ParsedShellRedirect) {
  const { operator } = redirect;
  const descriptor =
    overflowPrefix(redirect) === null
      ? (redirect.descriptor?.value ?? null)
      : null;
  const fd = Number(descriptor ?? (operator.startsWith("<") ? "0" : "1"));
  const path =
    redirect.kind !== "file"
      ? undefined
      : redirect.destination?.kind === "literal"
        ? redirect.destination.value
        : null;
  const duplicates = operator === ">&" || operator === "<&";
  const duplicateFd =
    duplicates && typeof path === "string" && /^\d+$/.test(path)
      ? Number(path)
      : null;
  const combined = operator === "&>" || operator === "&>>";
  return { descriptor, fd, path, duplicates, duplicateFd, combined };
}

export function fileSink(path: string, mode: "overwrite" | "append"): FlowSink {
  return path === "/dev/null"
    ? { kind: "discard" }
    : { kind: "file", path, mode };
}

export function shellFdTable(
  document: ParsedShellDocument,
  commandId: ParsedShellCommandId,
): ReadonlyMap<number, ShellFdBinding> {
  assertValidParsedShellDocument(document);
  const owner = document.commands[commandId];
  if (owner === undefined || owner.id !== commandId)
    throw new Error("command id invariant");

  const table = new Map<number, ShellFdBinding>([
    [0, { kind: "inherited-stdin" }],
    [1, toolOutput],
    [2, toolOutput],
  ]);
  const redirects = owner.redirectIds
    .map((id) => document.redirects[id]!)
    .sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
  for (const redirect of redirects) {
    const { fd, path, duplicates, duplicateFd, combined } =
      describeRedirect(redirect);
    if (redirect.kind !== "file") {
      table.set(fd, { kind: "source", redirectId: redirect.id });
      continue;
    }
    if (duplicateFd !== null) {
      table.set(fd, table.get(duplicateFd) ?? unknown);
      continue;
    }
    const both =
      combined || (redirect.operator === ">&" && fd === 1 && path !== "-");
    const binding =
      typeof path === "string" &&
      redirect.operator !== "<" &&
      (!duplicates || both)
        ? fileSink(
            path,
            redirect.operator.endsWith(">>") ? "append" : "overwrite",
          )
        : unknown;
    if (both) {
      table.set(1, binding);
      table.set(2, binding);
    } else {
      table.set(fd, binding);
    }
  }
  return table;
}

export function redirectEffect(
  redirect: ParsedShellRedirect,
): "stdin" | "stdout" | "stderr-into-stdout" | null {
  const { descriptor, fd, path, duplicates, duplicateFd, combined } =
    describeRedirect(redirect);
  if (combined) return "stdout";
  // Keep the read classifier's existing per-redirect rejection policy.
  const readFd = descriptor ?? String(fd);
  if (readFd === "0") return "stdin";
  if (readFd === "1") return "stdout";
  if (
    duplicateFd === 1 ||
    (!duplicates &&
      (path === null ||
        (path !== undefined && path.startsWith("/") && path !== "/dev/null")))
  )
    return readFd === "2" ? "stderr-into-stdout" : "stdout";
  return null;
}
