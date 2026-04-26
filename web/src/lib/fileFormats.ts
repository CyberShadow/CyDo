export type RenderableFormat = "markdown" | "svg" | null;

export function isMarkdownPath(filePath?: string | null): boolean {
  if (!filePath) return false;
  return /\.(md|mdx)$/i.test(filePath);
}

export function isSvgPath(filePath?: string | null): boolean {
  if (!filePath) return false;
  return /\.svg$/i.test(filePath);
}

/** Strip cat -n line number prefixes ("    1→" or "    1\t") from text. */
export function stripCatLineNumbers(text: string): string {
  return text.replace(/^\s*\d+[\u2192\t]/gm, "");
}

/**
 * Check if text content looks like a valid SVG document.
 * Used for content-sniffing when no filePath is available.
 */
export function looksLikeSvg(text: string): boolean {
  const trimmed = text.trim();
  const body = trimmed.startsWith("<?xml")
    ? trimmed.slice(trimmed.indexOf("?>") + 2).trim()
    : trimmed;
  if (!body.startsWith("<svg")) return false;
  if (!body.includes("</svg>")) return false;
  return true;
}

/** Detect renderable format from file path, or content-sniff if no path. */
export function detectRenderableFormat(
  filePath?: string | null,
  content?: string,
): RenderableFormat {
  if (isMarkdownPath(filePath)) return "markdown";
  if (isSvgPath(filePath)) return "svg";
  if (content && looksLikeSvg(stripCatLineNumbers(content).trim())) {
    return "svg";
  }
  return null;
}
