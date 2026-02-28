import { h } from "preact";
import { useMemo } from "preact/hooks";
import { marked } from "marked";

marked.setOptions({
  breaks: true,
  gfm: true,
});

interface Props {
  text: string;
  class?: string;
}

export function Markdown({ text, class: className }: Props) {
  const html = useMemo(() => marked.parse(text, { async: false }) as string, [text]);
  return <div class={`markdown ${className ?? ""}`} dangerouslySetInnerHTML={{ __html: html }} />;
}
