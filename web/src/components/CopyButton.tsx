import { useState, useCallback } from "preact/hooks";
import type { ComponentChildren } from "preact";
import copyIcon from "../icons/copy.svg?raw";
import checkIcon from "../icons/check.svg?raw";

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);

  const setCopiedBriefly = useCallback(() => {
    setCopyFailed(false);
    setCopied(true);
    setTimeout(() => {
      setCopied(false);
    }, 1500);
  }, []);

  const setCopyFailedBriefly = useCallback(() => {
    setCopied(false);
    setCopyFailed(true);
    setTimeout(() => {
      setCopyFailed(false);
    }, 1500);
  }, []);

  const onClick = useCallback(() => {
    void navigator.clipboard
      .writeText(text)
      .then(() => {
        setCopiedBriefly();
      })
      .catch(() => {
        // Clipboard access is browser/environment dependent; show local feedback.
        setCopyFailedBriefly();
      });
  }, [setCopiedBriefly, setCopyFailedBriefly, text]);

  return (
    <button
      class={`btn-copy${copied ? " copied" : ""}${copyFailed ? " failed" : ""}`}
      onClick={onClick}
      title={
        copyFailed ? "Copy failed" : copied ? "Copied!" : "Copy to clipboard"
      }
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
