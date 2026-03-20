import { h, Fragment } from "preact";

/**
 * ANSI escape sequence parser.
 * Converts SGR (Select Graphic Rendition) codes to styled Preact elements.
 * Strips all other escape sequences (cursor movement, etc.).
 */

// VS Code dark terminal palette
const COLORS_16 = [
  // Normal: black, red, green, yellow, blue, magenta, cyan, white
  "#666666",
  "#cd3131",
  "#0dbc79",
  "#e5e510",
  "#2472c8",
  "#bc3fbc",
  "#11a8cd",
  "#e5e5e5",
  // Bright: black, red, green, yellow, blue, magenta, cyan, white
  "#888888",
  "#f14c4c",
  "#23d18b",
  "#f5f543",
  "#3b8eea",
  "#d670d6",
  "#29b8db",
  "#ffffff",
];

function color256(n: number): string {
  if (n < 16) return COLORS_16[n]!;
  if (n < 232) {
    // 6x6x6 color cube
    n -= 16;
    const b = n % 6;
    const g = ((n - b) / 6) % 6;
    const r = ((n - b - g * 6) / 36) % 6;
    return `rgb(${r ? r * 40 + 55 : 0},${g ? g * 40 + 55 : 0},${b ? b * 40 + 55 : 0})`;
  }
  // Grayscale ramp
  const v = (n - 232) * 10 + 8;
  return `rgb(${v},${v},${v})`;
}

interface AnsiStyle {
  color?: string;
  backgroundColor?: string;
  fontWeight?: string;
  fontStyle?: string;
  textDecoration?: string;
  opacity?: string;
}

function applyCodes(codes: number[], style: AnsiStyle): void {
  let i = 0;
  while (i < codes.length) {
    const c = codes[i]!;
    if (c === 0) {
      delete style.color;
      delete style.backgroundColor;
      delete style.fontWeight;
      delete style.fontStyle;
      delete style.textDecoration;
      delete style.opacity;
    } else if (c === 1) {
      style.fontWeight = "bold";
    } else if (c === 2) {
      style.opacity = "0.7";
    } else if (c === 3) {
      style.fontStyle = "italic";
    } else if (c === 4) {
      style.textDecoration = "underline";
    } else if (c === 22) {
      delete style.fontWeight;
      delete style.opacity;
    } else if (c === 23) {
      delete style.fontStyle;
    } else if (c === 24) {
      delete style.textDecoration;
    } else if (c >= 30 && c <= 37) {
      style.color = COLORS_16[c - 30];
    } else if (c === 38 && codes[i + 1] === 5) {
      style.color = color256(codes[i + 2] ?? 0);
      i += 2;
    } else if (c === 38 && codes[i + 1] === 2) {
      style.color = `rgb(${codes[i + 2] ?? 0},${codes[i + 3] ?? 0},${codes[i + 4] ?? 0})`;
      i += 4;
    } else if (c === 39) {
      delete style.color;
    } else if (c >= 40 && c <= 47) {
      style.backgroundColor = COLORS_16[c - 40];
    } else if (c === 48 && codes[i + 1] === 5) {
      style.backgroundColor = color256(codes[i + 2] ?? 0);
      i += 2;
    } else if (c === 48 && codes[i + 1] === 2) {
      style.backgroundColor = `rgb(${codes[i + 2] ?? 0},${codes[i + 3] ?? 0},${codes[i + 4] ?? 0})`;
      i += 4;
    } else if (c === 49) {
      delete style.backgroundColor;
    } else if (c >= 90 && c <= 97) {
      style.color = COLORS_16[c - 90 + 8];
    } else if (c >= 100 && c <= 107) {
      style.backgroundColor = COLORS_16[c - 100 + 8];
    }
    i++;
  }
}

// Matches CSI sequences (\x1b[...X) and OSC sequences (\x1b]...\x07 or \x1b]...\x1b\\)
const ESCAPE_RE =
  /\x1b\[([0-9;]*?)([A-Za-z])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;

function hasStyleProps(style: AnsiStyle): boolean {
  return (
    style.color !== undefined ||
    style.backgroundColor !== undefined ||
    style.fontWeight !== undefined ||
    style.fontStyle !== undefined ||
    style.textDecoration !== undefined ||
    style.opacity !== undefined
  );
}

export function hasAnsi(text: string): boolean {
  return text.includes("\x1b[");
}

export function renderAnsi(text: string): h.JSX.Element {
  const children: (h.JSX.Element | string)[] = [];
  const style: AnsiStyle = {};
  let lastIndex = 0;
  let idx = 0;

  ESCAPE_RE.lastIndex = 0;
  let match;
  while ((match = ESCAPE_RE.exec(text)) !== null) {
    // Text before this escape
    if (match.index > lastIndex) {
      const chunk = text.slice(lastIndex, match.index);
      if (hasStyleProps(style)) {
        children.push(h("span", { key: idx++, style: { ...style } }, chunk));
      } else {
        children.push(chunk);
      }
    }
    lastIndex = match.index + match[0].length;

    // Only process SGR sequences (ending in 'm')
    if (match[2] === "m") {
      const codeStr = match[1];
      const codes = codeStr ? codeStr.split(";").map(Number) : [0];
      applyCodes(codes, style);
    }
    // All other escape sequences are silently stripped
  }

  // Remaining text
  if (lastIndex < text.length) {
    const chunk = text.slice(lastIndex);
    if (hasStyleProps(style)) {
      children.push(h("span", { key: idx++, style: { ...style } }, chunk));
    } else {
      children.push(chunk);
    }
  }

  return h(Fragment, null, ...children);
}
