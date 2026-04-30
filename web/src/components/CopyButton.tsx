import { useState, useCallback } from "preact/hooks";
import type { ComponentChildren } from "preact";
import copyIcon from "../icons/copy.svg?raw";
import checkIcon from "../icons/check.svg?raw";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  const setCopiedBriefly = useCallback(() => {
    setCopied(true);
    setTimeout(() => {
      setCopied(false);
    }, 1500);
  }, []);

  const onClick = useCallback(() => {
    void navigator.clipboard
      .writeText(text)
      .then(() => {
        setCopiedBriefly();
      })
      .catch(() => {});
  }, [setCopiedBriefly, text]);

  return (
    <button
      class={`btn-copy${copied ? " copied" : ""}`}
      onClick={onClick}
      title={copied ? "Copied!" : "Copy to clipboard"}
    >
      <span
        class="action-icon"
        dangerouslySetInnerHTML={{ __html: copied ? checkIcon : copyIcon }}
      />
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
