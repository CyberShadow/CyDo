import { CopyButton } from "./CopyButton";

export function PathDisplay({ path }: { path: string }) {
  const slash = path.lastIndexOf("/");
  return (
    <span class="tool-path-wrap">
      <span class="tool-subtitle-path">
        {slash === -1 ? (
          path
        ) : (
          <>
            <span class="tool-path-prefix">{path.slice(0, slash)}/</span>
            <span class="tool-path-leaf">{path.slice(slash + 1)}</span>
          </>
        )}
      </span>
      <span
        onClick={(e) => {
          e.stopPropagation();
        }}
      >
        <CopyButton text={path} />
      </span>
    </span>
  );
}
