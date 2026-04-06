import type { Notice } from "../protocol";

interface Props {
  notices: Record<string, Notice>;
}

export function NoticeBar({ notices }: Props) {
  const entries = Object.entries(notices);
  if (entries.length === 0) return null;
  return (
    <div class="notice-bar">
      {entries.map(([id, n]) => (
        <div key={id} class={`notice-item notice-${n.level}`}>
          <strong>{n.description}</strong>
          {n.impact && <span class="notice-impact"> {n.impact}</span>}
          {n.action && <span class="notice-action"> {n.action}</span>}
        </div>
      ))}
    </div>
  );
}
