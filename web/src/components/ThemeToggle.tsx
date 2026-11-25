import type { Theme } from "../useTheme";
import sunIcon from "../icons/sun.svg?raw";
import moonIcon from "../icons/moon.svg?raw";

export function ThemeToggle({
  theme,
  onToggle,
  corner,
}: {
  theme: Theme;
  onToggle: () => void;
  corner?: boolean;
}) {
  return (
    <button
      class={corner ? "theme-toggle theme-toggle-corner" : "theme-toggle"}
      onClick={onToggle}
      title={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
    >
      <span
        class="action-icon"
        dangerouslySetInnerHTML={{
          __html: theme === "dark" ? sunIcon : moonIcon,
        }}
      />
    </button>
  );
}
