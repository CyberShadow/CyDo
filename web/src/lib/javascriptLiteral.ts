import type { Node } from "web-tree-sitter";
import type { FlowValue } from "./contentFlow";
import {
  simplifyProjectionPoints,
  type SourceProjectionPoint,
} from "./sourceTree";

const simpleEscapes = new Map([
  ["n", "\n"],
  ["t", "\t"],
  ["r", "\r"],
  ["b", "\b"],
  ["f", "\f"],
  ["v", "\v"],
]);

function cookEscape(
  raw: string,
  start: number,
): { text: string; end: number } | null {
  const escape = raw.charAt(start + 1);
  let end = start + 2;
  if (escape === "\r" && raw[end] === "\n") end++;
  if (/^[\r\n\u2028\u2029]$/.test(escape)) return { text: "", end };
  const simple = simpleEscapes.get(escape);
  if (simple !== undefined) return { text: simple, end };
  if (escape === "0" && !/^[0-9]/.test(raw.charAt(end)))
    return { text: "\0", end };
  if (escape === "" || /^[0-9]$/.test(escape)) return null;
  if (escape === "x") {
    const hex = raw.slice(end, end + 2);
    return /^[0-9a-f]{2}$/i.test(hex)
      ? { text: String.fromCharCode(Number.parseInt(hex, 16)), end: end + 2 }
      : null;
  }
  if (escape === "u") {
    end = raw[end] === "{" ? raw.indexOf("}", end) + 1 : end + 4;
    if (end <= start) return null;
    const text = decodeJavaScriptUnicodeEscape(raw.slice(start + 1, end));
    return text === null ? null : { text, end };
  }
  const unit = String.fromCodePoint(raw.codePointAt(start + 1)!);
  return { text: unit, end: start + 1 + unit.length };
}

export function decodeJavaScriptUnicodeEscape(escape: string): string | null {
  if (/^u[0-9a-f]{4}$/i.test(escape)) {
    return String.fromCharCode(Number.parseInt(escape.slice(1), 16));
  }
  const match = /^u\{([0-9a-f]+)\}$/i.exec(escape);
  if (match === null) return null;
  const codePoint = Number.parseInt(match[1]!, 16);
  return codePoint <= 0x10ffff ? String.fromCodePoint(codePoint) : null;
}

export function decodeJavaScriptLiteral(
  node: Node,
  mode: "cooked" | "raw",
): FlowValue | null {
  const start = node.startIndex + 1;
  const end = node.endIndex - 1;
  let cursor = start;
  for (const child of node.namedChildren) {
    if (
      child.startIndex !== cursor ||
      (child.type !== "string_fragment" && child.type !== "escape_sequence")
    )
      return null;
    cursor = child.endIndex;
  }
  if (cursor !== end) return null;

  const spelling = node.text;
  const template = node.type === "template_string";
  const quote = spelling.charAt(0);
  if (
    spelling.length < 2 ||
    spelling.at(-1) !== quote ||
    (template ? quote !== "`" : quote !== '"' && quote !== "'")
  )
    return null;

  const raw = spelling.slice(1, -1);
  const points: SourceProjectionPoint[] = [{ child: 0, parent: 0 }];
  let text = "";
  for (let offset = 0; offset < raw.length; ) {
    const unit = raw.charAt(offset);
    let decoded = unit;
    if (mode === "cooked" && unit === "\\") {
      const escape = cookEscape(raw, offset);
      if (escape === null) return null;
      ({ text: decoded, end: offset } = escape);
    } else {
      if (!template && (unit === "\r" || unit === "\n" || unit === quote))
        return null;
      offset++;
      if (template && unit === "\r") {
        if (raw[offset] === "\n") offset++;
        decoded = "\n";
      }
    }
    if (decoded !== "") {
      text += decoded;
      points.push({ child: text.length, parent: offset });
    }
  }
  points[points.length - 1]!.parent = end - start;
  return {
    text,
    projection: { points: [...simplifyProjectionPoints(points)] },
  };
}
