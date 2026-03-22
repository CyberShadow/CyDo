import { useState, useCallback } from "preact/hooks";
import type { ComponentChildren } from "preact";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  const onClick = useCallback(() => {
    void navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => {
        setCopied(false);
      }, 1500);
    });
  }, [text]);

  return (
    <button
      class={`btn-copy${copied ? " copied" : ""}`}
      onClick={onClick}
      title={copied ? "Copied!" : "Copy to clipboard"}
    >
      {copied ? "✓" : "⧉"}
    </button>
  );
}

export function CodePre({
  class: className,
  copyText,
  children,
}: {
  class?: string;
  copyText: string;
  children: ComponentChildren;
}) {
  return (
    <div class="code-pre-wrap">
      <CopyButton text={copyText} />
      <pre class={className}>{children}</pre>
    </div>
  );
}
