// URL construction/decoding for the `/<workspace>/<project>/...` route family.

export function encodeProjectName(projectName: string): string {
  return projectName.replace(/\//g, ":");
}

export function decodeProjectSegment(segment: string): string {
  return segment.replace(/:/g, "/");
}

function decodePathSegment(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

/** Read task selection and project scope from the router's pathname. */
export function parseRoute(path: string): {
  workspace: string | null;
  project: string | null;
  tid: string | null;
} {
  const segments = path.split("/").filter(Boolean);
  const [first, second, third, fourth] = segments;
  if (first === "task" && second && segments.length === 2)
    return { workspace: null, project: null, tid: decodePathSegment(second) };
  if (first === "archive" && segments.length <= 2)
    return {
      workspace: null,
      project: null,
      tid: second ? `archive:${decodePathSegment(second)}` : "archive",
    };
  if (first === "import" && segments.length === 1)
    return { workspace: null, project: null, tid: "import" };
  const scoped =
    segments.length === 2 ||
    (segments.length === 3 && (third === "archive" || third === "import")) ||
    (segments.length === 4 &&
      (third === "archive" || third === "task" || third === "session"));
  if (!first || !second || !scoped)
    return { workspace: null, project: null, tid: null };

  const workspace = decodePathSegment(first);
  const project = decodeProjectSegment(decodePathSegment(second));
  if (third === "archive")
    return {
      workspace,
      project,
      tid: fourth ? `archive:${decodePathSegment(fourth)}` : "archive",
    };
  if (third === "import") return { workspace, project, tid: "import" };
  return {
    workspace,
    project,
    tid:
      fourth && (third === "task" || third === "session")
        ? decodePathSegment(fourth)
        : null,
  };
}

export function buildProjectHref(
  workspace: string,
  projectName: string,
): string {
  return `/${workspace}/${encodeProjectName(projectName)}`;
}

export function buildScopedHref(
  workspace: string | null,
  projectName: string | null,
  suffix: string,
): string {
  if (workspace && projectName) {
    return `${buildProjectHref(workspace, projectName)}${suffix}`;
  }
  return suffix;
}

export function taskPath(
  workspace: string,
  projectName: string,
  tid: number | string,
): string {
  return `${buildProjectHref(workspace, projectName)}/task/${tid}`;
}

/**
 * The path a task URL should be rewritten to, or null when the URL is already
 * canonical or the task's project cannot be resolved.
 *
 * The comparison is against the round-trip of our own encoding, so it is a fixed
 * point of encode∘parse: a project name containing ':' cannot cause a redirect loop.
 */
export function canonicalTaskRedirect(args: {
  tid: number;
  taskWorkspace: string | null;
  taskProject: string | null;
  urlWorkspace: string | null;
  urlProject: string | null;
}): string | null {
  const { tid, taskWorkspace, taskProject, urlWorkspace, urlProject } = args;
  if (taskWorkspace === null || taskProject === null) return null;
  const canonicalProject = decodeProjectSegment(encodeProjectName(taskProject));
  if (urlWorkspace === taskWorkspace && urlProject === canonicalProject) {
    return null;
  }
  return taskPath(taskWorkspace, taskProject, tid);
}
