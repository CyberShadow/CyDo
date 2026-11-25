// @vitest-environment jsdom
import { beforeAll, it, vi } from "vitest";
import { joinedRows } from "../test-support/preactAct";
import {
  initFailure,
  warmHighlighter,
} from "./ToolCall.shellSourceTree.fixture";

vi.mock("../lib/shellSemantic", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/shellSemantic")>()),
  useShellSemantic: () => null,
}));

beforeAll(warmHighlighter("bash"));
const run = joinedRows();

it("keeps highlighted raw input after 'urls' parser initialization failure", (context) =>
  run(context, (row) => initFailure(row, "urls")));
