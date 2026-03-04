import { h, type FunctionComponent } from "preact";
import { memo } from "preact/compat";
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

export const Markdown: FunctionComponent<Props> = memo(
  ({ text, class: className }: Props) => {
    const html = useMemo(
      () => marked.parse(text, { async: false }) as string,
      [text],
    );
    return (
      <div
        class={`markdown ${className ?? ""}`}
        dangerouslySetInnerHTML={{ __html: html }}
      />
    );
  },
);
