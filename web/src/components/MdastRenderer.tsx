import viewFileIcon from "../icons/view-file.svg?raw";
import {
  h,
  Fragment,
  createContext,
  type ComponentChildren,
  type VNode,
} from "preact";
import { useContext, useEffect, useRef, useState } from "preact/hooks";
import { useHighlight, renderHighlightedSource } from "../highlight";
import { useCurrentTheme } from "../useTheme";
import { CopyButton, CodePre } from "./CopyButton";
import { LocalFileContext } from "./LocalFileContext";
import { LiveFilePreview } from "./file-preview/LiveFilePreview";
import {
  collectLocalFileLinks,
  type FileLinkNode,
  type LinkTarget,
} from "../lib/localFileLinks";

import type {
  Root,
  RootContent,
  PhrasingContent,
  ListItem as MdastListItem,
  Table,
  TableRow,
  TableCell,
  Parent,
} from "mdast";

// Render the full AST root
export function MdastRenderer({ ast }: { ast: Root }): VNode {
  return h(
    Fragment,
    null,
    ast.children.map((node, i) => <BlockNode key={i} node={node} />),
  );
}

// Type guard for nodes that have children
function isParent(
  node: RootContent | PhrasingContent,
): node is Parent & (RootContent | PhrasingContent) {
  return "children" in node;
}

// Render a block-level node
function BlockNode({ node }: { node: RootContent }): VNode | null {
  switch (node.type) {
    case "heading":
    case "paragraph": {
      const tag = node.type === "heading" ? (`h${node.depth}` as const) : "p";
      return (
        <LinkHost nodes={node.children}>
          {h(tag, null, <InlineChildren nodes={node.children} />)}
        </LinkHost>
      );
    }
    case "code":
      if (node.lang === "mermaid") {
        return <MermaidBlock code={node.value} />;
      }
      return <CodeBlock lang={node.lang ?? null} code={node.value} />;
    case "blockquote":
      return (
        <blockquote>
          {node.children.map((child, i) => (
            <BlockNode key={i} node={child} />
          ))}
        </blockquote>
      );
    case "list": {
      const items = node.children;
      const isTask = items.some((li) => li.checked != null);
      const Tag = node.ordered ? "ol" : "ul";
      return (
        <Tag
          class={isTask ? "task-list" : undefined}
          start={node.ordered && node.start != null ? node.start : undefined}
        >
          {items.map((li, i) => (
            <ListItemNode key={i} node={li} isTask={isTask} />
          ))}
        </Tag>
      );
    }
    case "thematicBreak":
      return <hr />;
    case "table":
      return <TableNode node={node} />;
    case "html":
      // Render raw HTML as escaped text — do NOT inject as innerHTML
      return (
        <CodePre class="html-raw" copyText={node.value}>
          <code>{node.value}</code>
        </CodePre>
      );
    case "definition":
      return null; // metadata, not rendered
    default:
      // Fallback: render children if present, otherwise skip
      if (isParent(node)) {
        return h(
          Fragment,
          null,
          (node.children as RootContent[]).map((child, i) => (
            <BlockNode key={i} node={child} />
          )),
        );
      }
      return null;
  }
}

// Render a list item
function ListItemNode({
  node,
  isTask,
}: {
  node: MdastListItem;
  isTask: boolean;
}): VNode {
  if (isTask && node.checked != null) {
    return (
      <li class="task-list-item">
        <LinkHost
          nodes={node.children.flatMap((child) =>
            child.type === "paragraph" ? child.children : [],
          )}
        >
          <label>
            <input type="checkbox" checked={node.checked} disabled />
            {node.children.map((child, i) => {
              // For task items, paragraphs are rendered inline (unwrap the <p>)
              if (child.type === "paragraph") {
                return <InlineChildren key={i} nodes={child.children} />;
              }
              return <BlockNode key={i} node={child} />;
            })}
          </label>
        </LinkHost>
      </li>
    );
  }
  return (
    <li>
      {node.children.map((child, i) => (
        <BlockNode key={i} node={child} />
      ))}
    </li>
  );
}

// Render a GFM table
function TableNode({ node }: { node: Table }): VNode {
  const align: (string | null | undefined)[] = node.align ?? [];
  const rows: TableRow[] = node.children;
  const headerRow: TableRow | undefined = rows[0];
  const bodyRows = rows.slice(1);

  const alignStyle = (i: number) => {
    const a = align[i];
    return a ? { textAlign: a } : undefined;
  };

  return (
    <LinkHost nodes={rows.flatMap((row) => row.children)}>
      <table>
        {headerRow && (
          <thead>
            <tr>
              {headerRow.children.map((cell: TableCell, i: number) => (
                <th key={i} style={alignStyle(i)}>
                  <InlineChildren nodes={cell.children} />
                </th>
              ))}
            </tr>
          </thead>
        )}
        {bodyRows.length > 0 && (
          <tbody>
            {bodyRows.map((row: TableRow, ri: number) => (
              <tr key={ri}>
                {row.children.map((cell: TableCell, ci: number) => (
                  <td key={ci} style={alignStyle(ci)}>
                    <InlineChildren nodes={cell.children} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        )}
      </table>
    </LinkHost>
  );
}

// Render inline/phrasing content children
function InlineChildren({ nodes }: { nodes: PhrasingContent[] }): VNode {
  if (nodes.length === 0) return h(Fragment, null);
  return h(
    Fragment,
    null,
    nodes.map((node, i) => <InlineNode key={i} node={node} />),
  );
}

// Render a single inline/phrasing node
function InlineNode({ node }: { node: PhrasingContent }): VNode | null {
  switch (node.type) {
    case "text":
      return h(Fragment, null, node.value);
    case "strong":
      return (
        <strong>
          <InlineChildren nodes={node.children} />
        </strong>
      );
    case "emphasis":
      return (
        <em>
          <InlineChildren nodes={node.children} />
        </em>
      );
    case "delete":
      return (
        <del>
          <InlineChildren nodes={node.children} />
        </del>
      );
    case "inlineCode":
      return <code>{node.value}</code>;
    case "link":
    case "image":
      return <InlineLink node={node} />;
    case "break":
      return <br />;
    case "html":
      return h(Fragment, null, node.value);
    default:
      // Fallback for unknown inline types
      if (isParent(node)) {
        return <InlineChildren nodes={node.children as PhrasingContent[]} />;
      }
      if ("value" in node && typeof node.value === "string") {
        return h(Fragment, null, node.value);
      }
      return null;
  }
}

type HostedLink =
  | Extract<LinkTarget, { kind: "unresolved" }>
  | (Extract<LinkTarget, { kind: "local" }> & {
      expanded: boolean;
      toggle: () => void;
    });

interface LinkHostState {
  links: ReadonlyMap<FileLinkNode, HostedLink>;
  controlsByAnchor: ReadonlyMap<FileLinkNode, readonly VNode[]>;
}

const LinkHostContext = createContext<LinkHostState | null>(null);
const InsideAnchorContext = createContext(false);

function useLinkHost(nodes: readonly (PhrasingContent | TableCell)[]) {
  const access = useContext(LocalFileContext);
  const [overrides, setOverrides] = useState<ReadonlyMap<string, boolean>>(
    () => new Map(),
  );
  const links = new Map<FileLinkNode, HostedLink>();
  const controlsByAnchor = new Map<FileLinkNode, VNode[]>();
  const panels: VNode[] = [];
  const occurrences = new Map<string, number>();
  for (const { node, target, anchor } of collectLocalFileLinks(
    nodes,
    access?.baseDir ?? null,
  )) {
    if (target.kind === "unresolved") {
      links.set(node, target);
      continue;
    }

    const { path } = target;
    const group = JSON.stringify([node.type, path]);
    const occurrence = occurrences.get(group) ?? 0;
    occurrences.set(group, occurrence + 1);
    const key = `${group}:${occurrence}`;
    const expanded =
      overrides.get(key) ??
      (node.type === "image" && !access?.ancestorPaths.includes(path));
    const toggle = () => {
      setOverrides((previous) => new Map(previous).set(key, !expanded));
    };
    links.set(node, { ...target, expanded, toggle });
    if (access && anchor) {
      const controls = controlsByAnchor.get(anchor) ?? [];
      controls.push(
        <LocalFileControls
          key={key}
          path={path}
          expanded={expanded}
          toggle={toggle}
        />,
      );
      controlsByAnchor.set(anchor, controls);
    }
    if (access && expanded) {
      panels.push(
        <figure key={key} class="local-file-expansion">
          <figcaption class="local-file-expansion-caption" title={path}>
            {path}
          </figcaption>
          <div class="local-file-expansion-body">
            <LiveFilePreview path={path} />
          </div>
        </figure>,
      );
    }
  }
  return { links, controlsByAnchor, panels };
}

function LinkHost({
  nodes,
  children,
}: {
  nodes: readonly (PhrasingContent | TableCell)[];
  children: ComponentChildren;
}) {
  const { panels, ...host } = useLinkHost(nodes);
  return (
    <>
      <LinkHostContext.Provider value={host}>
        {children}
      </LinkHostContext.Provider>
      {panels.length > 0 && <div class="local-file-expansions">{panels}</div>}
    </>
  );
}

function InlineLink({ node }: { node: FileLinkNode }) {
  const access = useContext(LocalFileContext);
  const host = useContext(LinkHostContext);
  if (!host) throw new Error("Markdown link has no host");
  const insideAnchor = useContext(InsideAnchorContext);
  const link = host.links.get(node);
  const label =
    node.type === "link" ? (
      <InlineChildren nodes={node.children} />
    ) : (
      (node.alt ?? "")
    );
  if (!link) {
    if (node.type === "image") {
      return (
        <img
          src={node.url}
          alt={node.alt ?? ""}
          title={node.title ?? undefined}
        />
      );
    }
    if (insideAnchor) return <>{label}</>;
    return (
      <>
        <a
          href={node.url}
          title={node.title ?? undefined}
          target="_blank"
          rel="noopener noreferrer"
        >
          <InsideAnchorContext.Provider value={true}>
            {label}
          </InsideAnchorContext.Provider>
        </a>
        {host.controlsByAnchor.get(node)}
      </>
    );
  }
  if (!access || link.kind === "unresolved") {
    const title =
      access && link.kind === "unresolved"
        ? link.reason
        : `${link.kind === "local" ? link.path : node.url} (not available here)`;
    return (
      <span class="local-file-link local-file-link-inert" title={title}>
        {label}
      </span>
    );
  }
  const { path, expanded, toggle } = link;
  return (
    <span class="local-file-link">
      <span class="local-file-link-label" title={node.title ?? path}>
        {label}
      </span>
      {!insideAnchor && (
        <LocalFileControls path={path} expanded={expanded} toggle={toggle} />
      )}
    </span>
  );
}

function LocalFileControls({
  path,
  expanded,
  toggle,
}: {
  path: string;
  expanded: boolean;
  toggle: () => void;
}) {
  const access = useContext(LocalFileContext)!;
  const action = expanded ? "Collapse" : "Expand";
  return (
    <span class="local-file-link-controls">
      <button
        type="button"
        class="msg-action-btn"
        aria-expanded={expanded}
        aria-label={`${action} ${path}`}
        title={action}
        onClick={toggle}
      >
        <span class="action-icon" aria-hidden="true">
          <svg viewBox="0 0 12 12" fill="currentColor">
            <path
              d={expanded ? "M2 3.5L6 8.5L10 3.5Z" : "M3.5 2L8.5 6L3.5 10Z"}
            />
          </svg>
        </span>
      </button>
      <button
        type="button"
        class="msg-action-btn"
        aria-label={`Open ${path} in the file viewer`}
        title="Open in file viewer"
        onClick={() => {
          access.openInFileViewer(path);
        }}
      >
        <span
          class="action-icon"
          dangerouslySetInnerHTML={{ __html: viewFileIcon }}
        />
      </button>
    </span>
  );
}

// Mermaid diagram — lazy-loads the mermaid library on first use
let mermaidPromise: Promise<typeof import("mermaid")> | null = null;
let mermaidCurrentTheme: string | null = null;

function getMermaid(theme: "default" | "dark") {
  if (!mermaidPromise) {
    mermaidPromise = import("mermaid").then(async (m) => {
      const initialize = m.default.initialize.bind(m.default) as unknown as (
        options: Parameters<typeof m.default.initialize>[0],
      ) => unknown;
      await Promise.resolve(initialize({ startOnLoad: false, theme }));
      mermaidCurrentTheme = theme;
      return m;
    });
  } else if (mermaidCurrentTheme !== theme) {
    mermaidPromise = mermaidPromise.then(async (m) => {
      const initialize = m.default.initialize.bind(m.default) as unknown as (
        options: Parameters<typeof m.default.initialize>[0],
      ) => unknown;
      await Promise.resolve(initialize({ startOnLoad: false, theme }));
      mermaidCurrentTheme = theme;
      return m;
    });
  }
  return mermaidPromise;
}

function MermaidBlock({ code }: { code: string }): VNode {
  const containerRef = useRef<HTMLDivElement>(null);
  const cancelledRef = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const appTheme = useCurrentTheme();
  const mermaidTheme = appTheme === "light" ? "default" : "dark";

  useEffect(() => {
    if (!containerRef.current || !code.trim()) return;
    cancelledRef.current = false;
    setError(null);
    const id = `mermaid-${Math.random().toString(36).slice(2, 9)}`;

    void getMermaid(mermaidTheme)
      .then(async (m) => {
        if (cancelledRef.current) return;
        try {
          const { svg } = await m.default.render(id, code);
          // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- ref mutated by cleanup during await
          if (!cancelledRef.current && containerRef.current) {
            containerRef.current.innerHTML = svg;
            setError(null);
          }
        } catch (e) {
          // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- ref mutated by cleanup during await
          if (!cancelledRef.current) {
            setError(e instanceof Error ? e.message : String(e));
          }
        }
      })
      .catch((e: unknown) => {
        if (!cancelledRef.current) {
          setError(e instanceof Error ? e.message : String(e));
        }
      });

    return () => {
      cancelledRef.current = true;
    };
  }, [code, mermaidTheme]);

  if (error) {
    return (
      <div class="mermaid-error">
        <pre class="language-mermaid">
          <code>{code}</code>
        </pre>
        <div class="mermaid-error-msg">{error}</div>
      </div>
    );
  }

  return <div class="mermaid-diagram" ref={containerRef} />;
}

// Code block with Shiki syntax highlighting
function CodeBlock({
  lang,
  code,
}: {
  lang: string | null;
  code: string;
}): VNode {
  // Incremark gives empty fences and single blank body lines the same value.
  const displayCode = code === "" ? "" : code + "\n";
  const tokens = useHighlight(displayCode, lang);
  return (
    <div class="code-pre-wrap">
      <CopyButton text={code} />
      <pre class={lang ? `language-${lang}` : undefined}>
        <code>{renderHighlightedSource(displayCode, tokens)}</code>
      </pre>
    </div>
  );
}
