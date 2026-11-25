import { useEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";

interface Props {
  as: "pre" | "div";
  class?: string;
  children: ComponentChildren;
}

export function StickyScroll({ as: Tag, class: className, children }: Props) {
  const ref = useRef<HTMLPreElement & HTMLDivElement>(null);
  const contentRef = useRef<HTMLSpanElement & HTMLDivElement>(null);
  const Content = Tag === "pre" ? "span" : "div";

  useEffect(() => {
    const el = ref.current!;
    let following = true;
    let pinnedTop: number | undefined;
    const onScroll = () => {
      const top = el.scrollTop;
      // A scroll event from the pin can arrive after content has grown again.
      if (following && top === pinnedTop) return;
      following = el.scrollHeight - el.clientHeight - top < 2;
    };
    el.addEventListener("scroll", onScroll, { passive: true });

    const observer = new ResizeObserver(() => {
      if (!following) return;
      el.scrollTop = el.scrollHeight;
      pinnedTop = el.scrollTop;
    });
    observer.observe(el);
    observer.observe(contentRef.current!);
    return () => {
      observer.disconnect();
      el.removeEventListener("scroll", onScroll);
    };
  }, [Tag]);

  return (
    <Tag ref={ref} class={className} style={{ overflowAnchor: "none" }}>
      <Content ref={contentRef} class="sticky-scroll-content">
        {children}
      </Content>
    </Tag>
  );
}
