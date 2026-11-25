import type {
  Image,
  Link,
  PhrasingContent,
  RootContent,
  TableCell,
} from "mdast";

export type LinkTarget =
  | { kind: "web" }
  | { kind: "local"; path: string }
  | { kind: "unresolved"; reason: string };

export function resolvePosixPath(base: string, path: string): string {
  const parts: string[] = [];
  const absolute = path.startsWith("/") ? path : `${base}/${path}`;
  for (const part of absolute.split("/")) {
    if (part === "..") parts.pop();
    else if (part && part !== ".") parts.push(part);
  }
  return `/${parts.join("/")}`;
}

export function classifyLinkTarget(
  url: string,
  baseDir: string | null,
): LinkTarget {
  if (baseDir !== null && !baseDir.startsWith("/")) {
    throw new Error("A local file base directory must be absolute");
  }
  if (url.startsWith("#")) return { kind: "web" };
  if (/^file:/i.test(url)) {
    try {
      const parsed = new URL(url);
      if (parsed.hostname && parsed.hostname !== "localhost") {
        return { kind: "unresolved", reason: "file URL names another host" };
      }
      return {
        kind: "local",
        path: resolvePosixPath("/", decodeURIComponent(parsed.pathname)),
      };
    } catch {
      return { kind: "unresolved", reason: "malformed file URL" };
    }
  }

  const destination = url.split("#", 1)[0]!;
  const path = destination.replace(/:\d+(?::\d+)?$/, "");
  const fileWithLine = path !== destination && /^[^:]*[./][^:]*$/.test(path);
  if (
    url.startsWith("//") ||
    (!fileWithLine && /^[a-z][a-z0-9+.-]*:/i.test(url))
  ) {
    return { kind: "web" };
  }
  if (!path) return { kind: "unresolved", reason: "empty path" };
  if (!path.startsWith("/") && baseDir === null) {
    return {
      kind: "unresolved",
      reason: "relative path; the working directory is not known",
    };
  }
  return { kind: "local", path: resolvePosixPath(baseDir ?? "/", path) };
}

export type FileLinkNode = Link | Image;

export function collectLocalFileLinks(
  nodes: readonly (PhrasingContent | TableCell)[],
  baseDir: string | null,
) {
  const links: {
    node: FileLinkNode;
    anchor: Link | null;
    target: Exclude<LinkTarget, { kind: "web" }>;
  }[] = [];
  function visit(node: RootContent, anchor: Link | null) {
    if (node.type === "link" || node.type === "image") {
      const target = classifyLinkTarget(node.url, baseDir);
      if (target.kind !== "web") links.push({ node, target, anchor });
      else if (node.type === "link") anchor ??= node;
    }
    if ("children" in node) {
      for (const child of node.children) visit(child, anchor);
    }
  }
  for (const node of nodes) visit(node, null);
  return links;
}
