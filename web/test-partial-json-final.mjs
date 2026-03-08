#!/usr/bin/env node
/**
 * Final comprehensive test of the improved tryParsePartialJson.
 *
 * Invariants tested:
 * 1. Never returns null for non-empty input
 * 2. Never throws
 * 3. Monotonicity: JSON.stringify(result).length never decreases as input grows
 * 4. Semantic: parsed string values are prefixes of full values (allowing the
 *    last character to differ at escape-sequence boundaries)
 */

import { readFileSync, readdirSync } from "fs";
import { join } from "path";

// ---------------------------------------------------------------------------
// V1: Current implementation (for comparison)
// ---------------------------------------------------------------------------
function tryParsePartialJsonV1(partial) {
  if (!partial) return {};
  try { return JSON.parse(partial); } catch {}
  let attempt = partial;
  let inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) { i++; continue; }
    if (attempt[i] === '"') inString = !inString;
  }
  if (inString) attempt += '"';
  const stack = [];
  inString = false;
  for (let i = 0; i < attempt.length; i++) {
    if (attempt[i] === "\\" && inString) { i++; continue; }
    if (attempt[i] === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (attempt[i] === "{") stack.push("}");
    else if (attempt[i] === "[") stack.push("]");
    else if (attempt[i] === "}" || attempt[i] === "]") stack.pop();
  }
  attempt += stack.reverse().join("");
  try { return JSON.parse(attempt); } catch { return null; }
}

// ---------------------------------------------------------------------------
// V4: Improved implementation
// ---------------------------------------------------------------------------
function tryParsePartialJsonV4(partial) {
  if (!partial) return {};
  try { return JSON.parse(partial); } catch {}

  let s = partial;

  // Phase 1: Close any open string.
  let inString = false;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && inString) { i++; continue; }
    if (s[i] === '"') inString = !inString;
  }
  if (inString) {
    let trailingBs = 0;
    for (let j = s.length - 1; j >= 0; j--) {
      if (s[j] === "\\") trailingBs++;
      else break;
    }
    if (trailingBs % 2 === 1) s += "\\";
    s += '"';
  }

  // Phase 2: Track brackets and record clean boundary snapshots
  const snapshots = [];
  const stack = [];
  inString = false;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && inString) { i++; continue; }
    if (s[i] === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (s[i] === "{" || s[i] === "[") {
      stack.push(s[i] === "{" ? "}" : "]");
      snapshots.push({ pos: i + 1, stack: [...stack] });
    } else if (s[i] === "}" || s[i] === "]") {
      stack.pop();
      snapshots.push({ pos: i + 1, stack: [...stack] });
    } else if (s[i] === ",") {
      snapshots.push({ pos: i, stack: [...stack] });
    }
  }

  const closers = [...stack].reverse().join("");
  try { return JSON.parse(s + closers); } catch {}

  for (let i = snapshots.length - 1; i >= 0; i--) {
    const { pos, stack: snapStack } = snapshots[i];
    const c = [...snapStack].reverse().join("");
    try { return JSON.parse(s.slice(0, pos) + c); } catch {}
  }

  return {};
}

// ---------------------------------------------------------------------------
// Semantic check: partial value is prefix of full value,
// allowing the last char to differ (escape boundary).
// ---------------------------------------------------------------------------
function isSemanticPrefix(partialVal, fullVal) {
  if (typeof partialVal !== "string" || typeof fullVal !== "string") return true;
  if (partialVal.length === 0) return true;
  if (fullVal.startsWith(partialVal)) return true;
  // Allow the last character to differ (escape boundary mismatch)
  if (partialVal.length >= 1) {
    const prefix = partialVal.slice(0, -1);
    if (fullVal.startsWith(prefix)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Data collection
// ---------------------------------------------------------------------------
function extractToolInputs(jsonlDir, maxFiles) {
  const files = readdirSync(jsonlDir)
    .filter((f) => f.endsWith(".jsonl"))
    .sort()
    .slice(0, maxFiles);
  const toolInputs = [];
  for (const file of files) {
    let content;
    try { content = readFileSync(join(jsonlDir, file), "utf-8"); } catch { continue; }
    for (const line of content.split("\n")) {
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.type !== "assistant") continue;
      const blocks = msg.message?.content;
      if (!Array.isArray(blocks)) continue;
      for (const block of blocks) {
        if (block.type === "tool_use" && block.input && typeof block.input === "object") {
          toolInputs.push({ name: block.name, input: block.input, file, id: block.id });
        }
      }
    }
  }
  return toolInputs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const jsonlDir = join(process.env.HOME, ".claude/projects/-home-vladimir-work-cydo");
console.log("Extracting tool inputs...");
const toolInputs = extractToolInputs(jsonlDir, 50);
console.log(`Found ${toolInputs.length} tool_use blocks\n`);

let totalPrefixes = 0;
let v1Nulls = 0;
let v4Nulls = 0;
let v4Throws = 0;
let v4MonotonicViolations = 0;
let v4SemanticIssues = 0;
let v4EscapeBoundaryMismatches = 0; // expected, not bugs

const v4MonotonicFailures = [];
const v4SemanticFailures = [];

for (const ti of toolInputs) {
  const json = JSON.stringify(ti.input);
  let prevLen = 0;

  for (let n = 0; n <= json.length; n++) {
    const prefix = json.slice(0, n);
    totalPrefixes++;

    const v1 = tryParsePartialJsonV1(prefix);
    if (v1 === null) v1Nulls++;

    let v4;
    try {
      v4 = tryParsePartialJsonV4(prefix);
    } catch (e) {
      v4Throws++;
      prevLen = 0;
      continue;
    }
    if (v4 === null) {
      v4Nulls++;
      prevLen = 0;
      continue;
    }

    // Monotonicity
    const curLen = JSON.stringify(v4).length;
    if (curLen < prevLen) {
      v4MonotonicViolations++;
      if (v4MonotonicFailures.length < 30) {
        const prevResult = tryParsePartialJsonV4(json.slice(0, n - 1));
        v4MonotonicFailures.push({
          tool: ti.name, n, total: json.length, prevLen, curLen,
          prevResult: JSON.stringify(prevResult).slice(0, 120),
          curResult: JSON.stringify(v4).slice(0, 120),
          prevPrefix: json.slice(0, n - 1).slice(-80),
          curPrefix: prefix.slice(-80),
        });
      }
    }
    prevLen = curLen;

    // Semantic check
    if (typeof v4 === "object" && v4 !== null) {
      for (const [key, val] of Object.entries(v4)) {
        if (typeof val === "string" && typeof ti.input[key] === "string") {
          if (!isSemanticPrefix(val, ti.input[key])) {
            v4SemanticIssues++;
            if (v4SemanticFailures.length < 20) {
              v4SemanticFailures.push({
                tool: ti.name, key, n, total: json.length,
                partial: val.slice(0, 80),
                full: ti.input[key].slice(0, 80),
              });
            }
          } else if (!ti.input[key].startsWith(val)) {
            v4EscapeBoundaryMismatches++;
          }
        }
      }
    }
  }
}

console.log("=== Real data results ===");
console.log(`Total prefixes tested: ${totalPrefixes}`);
console.log(`V1 nulls: ${v1Nulls}`);
console.log(`V4 nulls: ${v4Nulls}`);
console.log(`V4 throws: ${v4Throws}`);
console.log(`V4 monotonic violations: ${v4MonotonicViolations}`);
console.log(`V4 semantic issues: ${v4SemanticIssues}`);
console.log(`V4 escape boundary mismatches (expected): ${v4EscapeBoundaryMismatches}`);
console.log();

if (v4MonotonicFailures.length > 0) {
  console.log("Monotonic violations:");
  for (const f of v4MonotonicFailures) {
    console.log(`  ${f.tool} [${f.n}/${f.total}]: len ${f.prevLen} → ${f.curLen}`);
    console.log(`    prev: ${f.prevResult}`);
    console.log(`    cur:  ${f.curResult}`);
  }
  console.log();
}

if (v4SemanticFailures.length > 0) {
  console.log("Semantic failures (REAL BUGS):");
  for (const f of v4SemanticFailures) {
    console.log(`  ${f.tool}.${f.key} [${f.n}/${f.total}]:`);
    console.log(`    Partial: ${JSON.stringify(f.partial)}`);
    console.log(`    Full:    ${JSON.stringify(f.full)}`);
  }
  console.log();
}

// Edge cases
console.log("=== Edge cases ===");
const edgeCases = [
  ['', {}, 'empty'],
  ['{', {}, 'lone brace'],
  ['{"', {}, 'open key quote'],
  ['{"f', {}, 'partial key'],
  ['{"foo"', {}, 'key no colon'],
  ['{"foo":', {}, 'key colon no value'],
  ['{"foo":"', {foo: ""}, 'open value quote'],
  ['{"foo":"bar', {foo: "bar"}, 'unclosed value'],
  ['{"foo":"bar"', {foo: "bar"}, 'value closed'],
  ['{"foo":"bar",', {foo: "bar"}, 'trailing comma'],
  ['{"foo":"bar","baz"', {foo: "bar"}, 'second key no colon'],
  ['{"foo":"bar","baz":', {foo: "bar"}, 'second key colon no value'],
  ['{"foo":"bar","baz":"q', {foo: "bar", baz: "q"}, 'second value partial'],
  ['{"a":[', {a: []}, 'open array'],
  ['{"a":["x"', {a: ["x"]}, 'array element'],
  ['{"a":["x",', {a: ["x"]}, 'array trailing comma'],
  ['{"a":{"b":"c"', {a: {b: "c"}}, 'nested value'],
  ['{"a":{"b":"c"}', {a: {b: "c"}}, 'nested closed'],
  ['{"a":{"b":', {a: {}}, 'nested key no value'],
  ['{"a":1', {a: 1}, 'number value'],
  ['{"a":true', {a: true}, 'boolean true'],
  ['{"a":false', {a: false}, 'boolean false'],
  ['{"a":null', {a: null}, 'null value'],
  ['{"a":tru', {}, 'partial true'],
  ['{"a":fal', {}, 'partial false'],
  ['{"a":nul', {}, 'partial null'],
  ['{"a":"test\\', {}, 'trailing backslash'],
  ['{"a":"test\\"', {a: 'test"'}, 'escaped quote'],
  ['{"a":"test\\\\', {a: 'test\\'}, 'escaped backslash'],
  ['{"a":"test\\\\\\', {}, 'three backslashes'],
  ['{"a":"line\\n', {a: 'line\n'}, 'escaped newline'],
  ['{"a":"tab\\t', {a: 'tab\t'}, 'escaped tab'],
  ['{"a":"\\u0041', {a: 'A'}, 'complete unicode'],
  ['{"a":[{"b":"c"},{"d":[', {a: [{b:"c"},{d:[]}]}, 'deep mixed'],
  ['{"a":{}', {a: {}}, 'empty nested obj'],
  ['{"a":[]', {a: []}, 'empty nested arr'],
  ['{"file_path":"/home/user/te', {file_path: "/home/user/te"}, 'partial path'],
  ['{"command":"ls -la /ho', {command: "ls -la /ho"}, 'partial command'],
  ['{"pattern":"**/*.ts","path":"/home/us', {pattern: "**/*.ts", path: "/home/us"}, 'grep partial path'],
];

let edgePassed = 0;
let edgeFailed = 0;
for (const [input, expected, desc] of edgeCases) {
  let result;
  try {
    result = tryParsePartialJsonV4(input);
  } catch (e) {
    edgeFailed++;
    console.log(`  THROW "${desc}": ${e.message}`);
    continue;
  }
  if (result === null) {
    edgeFailed++;
    console.log(`  NULL "${desc}"`);
    continue;
  }
  let ok = true;
  for (const [key, val] of Object.entries(expected)) {
    if (JSON.stringify(result[key]) !== JSON.stringify(val)) {
      ok = false;
      console.log(`  MISMATCH "${desc}": ${key} got ${JSON.stringify(result[key])}, expected ${JSON.stringify(val)}`);
    }
  }
  if (ok) edgePassed++;
  else edgeFailed++;
}
console.log(`Edge cases: ${edgePassed} passed, ${edgeFailed} failed`);
console.log();

// Monotonicity trace
console.log("=== Monotonicity trace ===");
const traceInput = '{"file_path":"/home/user/test.ts","old_string":"function foo() {\\n  return 1;\\n}","new_string":"function foo() {\\n  return 2;\\n}"}';
let prevTraceLen = 0;
let traceRegression = false;
for (let n = 0; n <= traceInput.length; n++) {
  const prefix = traceInput.slice(0, n);
  const result = tryParsePartialJsonV4(prefix);
  const curLen = JSON.stringify(result).length;
  if (curLen < prevTraceLen) {
    traceRegression = true;
    console.log(`  REGRESSION at ${n}: ${prevTraceLen} → ${curLen}`);
    console.log(`    Prefix: ${prefix.slice(-60)}`);
    console.log(`    Result: ${JSON.stringify(result).slice(0, 100)}`);
  }
  prevTraceLen = curLen;
}
if (!traceRegression) console.log("  No regressions in trace");
console.log();

// Summary
const hardIssues = v4Nulls + v4Throws + v4MonotonicViolations + v4SemanticIssues + edgeFailed;
if (hardIssues === 0) {
  console.log("ALL TESTS PASSED");
  console.log(`(${v4EscapeBoundaryMismatches} expected escape-boundary mismatches — not bugs)`);
} else {
  console.log(`ISSUES: ${hardIssues}`);
}
process.exit(hardIssues > 0 ? 1 : 0);
