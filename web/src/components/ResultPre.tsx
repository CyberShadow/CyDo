import type { ComponentChildren } from "preact";
import { hasAnsi, renderAnsi } from "../ansi";
import { CodePre } from "./CopyButton";

export function ResultPre({
  content,
  class: className,
  isError,
  children,
}: {
  content: string;
  class?: string;
  isError?: boolean;
  children?: ComponentChildren;
}) {
  const cls = `tool-result${isError ? " error" : ""}${
    className ? ` ${className}` : ""
  }`;
  return (
    <CodePre class={cls} copyText={content}>
      {children ?? (hasAnsi(content) ? renderAnsi(content) : content)}
    </CodePre>
  );
}
