import { createContext } from "preact";
import { useState, useEffect, useContext, useCallback } from "preact/hooks";

export type Theme = "dark" | "light";

export const ThemeContext = createContext<Theme>("dark");

export function useCurrentTheme(): Theme {
  return useContext(ThemeContext);
}

function getInitialTheme(): Theme {
  const stored = localStorage.getItem("theme");
  if (stored === "light" || stored === "dark") return stored;
  return "dark";
}

export function useTheme() {
  const [theme, setTheme] = useState<Theme>(getInitialTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("theme", theme);
  }, [theme]);

  const toggleTheme = useCallback(() => {
    setTheme((t) => (t === "dark" ? "light" : "dark"));
  }, []);

  return { theme, toggleTheme } as const;
}
