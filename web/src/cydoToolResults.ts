export interface CreatedTaskResult {
  tid: number;
  workspace: string;
  project_path: string;
  entry_point: string;
  status: "draft" | "started";
}

export function parseCreatedTaskResult(
  payload: unknown,
): CreatedTaskResult | undefined {
  if (typeof payload === "string") {
    try {
      payload = JSON.parse(payload) as unknown;
    } catch {
      return undefined;
    }
  }
  if (typeof payload !== "object" || payload === null) return undefined;
  const result = payload as Record<string, unknown>;
  if (result.isError === true) return undefined;
  if (result.structuredContent !== undefined) {
    return parseCreatedTaskResult(result.structuredContent);
  }
  const { tid, workspace, project_path, entry_point, status } = result;
  if (
    typeof tid !== "number" ||
    !Number.isSafeInteger(tid) ||
    tid <= 0 ||
    typeof workspace !== "string" ||
    typeof project_path !== "string" ||
    typeof entry_point !== "string" ||
    (status !== "draft" && status !== "started")
  ) {
    return undefined;
  }
  return { tid, workspace, project_path, entry_point, status };
}
