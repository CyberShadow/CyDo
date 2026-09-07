import type {
  ParsedShellDocument,
  ParsedShellEmbeddedInvocation,
  ParsedShellUnit,
} from "./shellParser";

function directCommandId(unit: ParsedShellUnit): number | null {
  if (unit.kind === "command") return unit.commandId;
  if (unit.kind === "redirected_statement" && unit.body.kind === "command")
    return unit.body.commandId;
  return null;
}

export function ownsWholeCommand(
  document: ParsedShellDocument,
  invocation: Extract<ParsedShellEmbeddedInvocation, { kind: "inline" }>,
): boolean {
  if (invocation.interpreter.language !== "bash" || invocation.child === null)
    return false;
  const command = document.commands[invocation.commandId]!;
  if (
    document.program.children.length !== 1 ||
    document.program.boundaries.length !== 0
  )
    return false;
  const soleUnit = document.program.children[0]!;
  const soleCommandId = directCommandId(soleUnit);
  if (soleCommandId !== invocation.commandId) return false;
  return command.redirectIds.every((redirectId) => {
    const redirect = document.redirects[redirectId]!;
    return (
      redirect.kind === "file" &&
      redirect.span.start >= invocation.payload.rawSpan.end
    );
  });
}
