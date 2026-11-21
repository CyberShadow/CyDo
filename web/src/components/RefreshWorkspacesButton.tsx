interface Props {
  onClick: () => void;
  scanState: "idle" | "requested" | "scanning";
  label: string;
}

export function RefreshWorkspacesButton({ onClick, scanState, label }: Props) {
  return (
    <button
      class="sidebar-new-btn refresh-workspaces-btn"
      onClick={onClick}
      title={label}
      aria-label={label}
      disabled={scanState !== "idle"}
    >
      {scanState === "scanning" ? (
        <span class="refresh-spinner" />
      ) : (
        <span class={scanState === "requested" ? "refresh-requested" : ""}>
          ↻
        </span>
      )}
    </button>
  );
}
