import { createContext } from "preact";
import { useContext } from "preact/hooks";

export const DevModeContext = createContext(false);

export function useDevMode(): boolean {
  return useContext(DevModeContext);
}
