// Tool identity helpers for agent-aware tool name matching.
//
// Built-in tool names are not globally unique — "Bash" means different things
// from Claude Code vs. a hypothetical same-named tool from another agent. These
// helpers produce qualified keys that incorporate the driver name for built-ins
// and the MCP server name for MCP tools, preventing cross-agent mismatches.

/** Produce a qualified key for a tool, incorporating driver name for built-ins.
 *  MCP tools: "server:name" (e.g. "cydo:Task")
 *  Agent built-ins: "driver/name" (e.g. "claude/Bash", "codex/fileChange")
 *  Fallback (no server or driver): bare name */
export function qualifiedToolKey(
  name: string,
  server?: string,
  driver?: string,
): string {
  if (server) return `${server}:${name}`;
  if (driver) return `${driver}/${name}`;
  return name;
}

/** Check if a tool matches one of the expected qualified identities.
 *  Handles agent-qualified ("claude/Bash") and server-qualified ("cydo:Task"). */
export function toolIs(
  name: string,
  driver: string | undefined,
  toolServer: string | undefined,
  ...expected: string[]
): boolean {
  const qualified = qualifiedToolKey(name, toolServer, driver);
  for (const e of expected) {
    if (e === qualified) return true;
  }
  return false;
}
