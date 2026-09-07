import {
  assertValidParsedShellDocument,
  type ParsedShellCommandId,
  type ParsedShellDocument,
} from "./shellParser";

export type ShellRedirectStateResult = Readonly<{
  literalStdoutPath: string | null;
  effectiveStdinRedirectId: number | null;
}>;

export function reduceShellRedirectState(
  document: ParsedShellDocument,
  ownerId: ParsedShellCommandId,
): ShellRedirectStateResult {
  assertValidParsedShellDocument(document);
  const owner = document.commands[ownerId];
  if (owner === undefined || owner.id !== ownerId)
    throw new Error("command id invariant");

  let literalStdoutPath: string | null = null;
  let effectiveStdinRedirectId: number | null = null;
  const redirects = owner.redirectIds
    .map((redirectId) => document.redirects[redirectId]!)
    .sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
  const literalDestination = (
    redirect: (typeof redirects)[number],
  ): string | null =>
    redirect.kind === "file" && redirect.destination?.kind === "literal"
      ? redirect.destination.value
      : null;

  for (const redirect of redirects) {
    const fd = redirect.descriptor?.value ?? null;
    if (redirect.kind === "heredoc" || redirect.kind === "herestring") {
      if (fd === null || fd === "0") effectiveStdinRedirectId = redirect.id;
      continue;
    }
    const destination = literalDestination(redirect);
    switch (redirect.operator) {
      case ">":
      case ">>":
      case ">|":
      case "&>":
      case "&>>":
        if (fd === null || fd === "1") literalStdoutPath = destination;
        break;
      case "<":
        if (fd === null || fd === "0") effectiveStdinRedirectId = redirect.id;
        break;
      case "<&":
        if (fd === null || fd === "0") effectiveStdinRedirectId = null;
        else if (fd === "1") literalStdoutPath = null;
        break;
      case ">&":
        if (fd === null || fd === "1")
          literalStdoutPath =
            destination !== null && !/^\d+$/.test(destination)
              ? destination
              : null;
        break;
    }
  }
  return { literalStdoutPath, effectiveStdinRedirectId };
}
