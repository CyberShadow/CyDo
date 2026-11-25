// @vitest-environment jsdom
import { beforeAll, it, vi } from "vitest";
import { joinedRows } from "../test-support/preactAct";
import { lifecycle, warmHighlighter } from "./ToolCall.shellSourceTree.fixture";

vi.mock("../lib/shellSemantic", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/shellSemantic")>()),
  useShellSemantic: () => null,
}));

beforeAll(warmHighlighter("bash"));
const run = joinedRows();

it("holds, settles, remounts, and rerenders with 'bytes' parser assets", (context) =>
  run(context, (row) => lifecycle(row, "bytes")));
