import { useEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";

interface Props {
  class?: string;
  children: ComponentChildren;
}

export function StickyScrollPre({ class: className, children }: Props) {
  const ref = useRef<HTMLPreElement>(null);
  const isAtBottom = useRef(true);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onScroll = () => {
      isAtBottom.current =
        el.scrollTop + el.clientHeight >= el.scrollHeight - 2;
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      el.removeEventListener("scroll", onScroll);
    };
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (el && isAtBottom.current) {
      el.scrollTop = el.scrollHeight;
    }
  });

  return (
    <pre ref={ref} class={className}>
      {children}
    </pre>
  );
}
