import { vi } from "vitest";
import { hangTimeout } from "./hangTimeout";

export function waitFor<T>(callback: () => T | Promise<T>): Promise<T> {
  return vi.waitFor(callback, hangTimeout);
}
