import { createContext, Fragment, type ComponentChildren } from "preact";
import { useContext } from "preact/hooks";
import { resolvePosixPath } from "../lib/localFileLinks";

export interface LocalFileAccess {
  tid: number;
  baseDir: string | null;
  ancestorPaths: readonly string[];
}

export const LocalFileContext = createContext<LocalFileAccess | null>(null);

export function useLiveFileAccess(path: string | null): LocalFileAccess | null {
  const access = useContext(LocalFileContext);
  return path?.startsWith("/") ? access : null;
}

export function LocalFileDocument({
  filePath,
  children,
}: {
  filePath: string;
  children: ComponentChildren;
}) {
  const access = useContext(LocalFileContext);
  if (!access) return <Fragment key={filePath}>{children}</Fragment>;
  const path =
    filePath.startsWith("/") || access.baseDir?.startsWith("/")
      ? resolvePosixPath(access.baseDir ?? "/", filePath)
      : null;
  const baseDir =
    path === null ? null : path.slice(0, path.lastIndexOf("/")) || "/";
  const ancestorPaths =
    path === null ? access.ancestorPaths : [...access.ancestorPaths, path];
  return (
    <LocalFileContext.Provider
      key={path ?? filePath}
      value={{ ...access, baseDir, ancestorPaths }}
    >
      {children}
    </LocalFileContext.Provider>
  );
}
