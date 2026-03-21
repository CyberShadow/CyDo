import { h, Fragment, type VNode } from "preact";
import { useHighlight, renderTokens } from "../highlight";

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
    case "heading": {
      const tag: `h${typeof node.depth}` = `h${node.depth}`;
      return h(tag, null, <InlineChildren nodes={node.children} />);
    }
    case "paragraph":
      return (
        <p>
          <InlineChildren nodes={node.children} />
        </p>
      );
    case "code":
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
        <pre class="html-raw">
          <code>{node.value}</code>
        </pre>
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
      return (
        <a
          href={node.url}
          title={node.title ?? undefined}
          target="_blank"
          rel="noopener noreferrer"
        >
          <InlineChildren nodes={node.children} />
        </a>
      );
    case "image":
      return (
        <img
          src={node.url}
          alt={node.alt ?? ""}
          title={node.title ?? undefined}
        />
      );
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

// Code block with Shiki syntax highlighting
function CodeBlock({
  lang,
  code,
}: {
  lang: string | null;
  code: string;
}): VNode {
  const tokens = useHighlight(code, lang);
  return (
    <pre class={lang ? `language-${lang}` : undefined}>
      <code>
        {tokens
          ? tokens.map((line, i) => (
              <span key={i}>
                {renderTokens(line)}
                {"\n"}
              </span>
            ))
          : code}
      </code>
    </pre>
  );
}
