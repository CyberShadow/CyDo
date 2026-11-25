// @vitest-environment jsdom
import { beforeAll, it } from "vitest";
import { joinedRows } from "../test-support/preactAct";
import {
  semanticInitFailure,
  warmHighlighter,
} from "./ToolCall.shellSourceTree.fixture";

beforeAll(warmHighlighter("bash"));
const run = joinedRows();

it("maps semantic parser initialization failure to a typed result without rejection", (context) =>
  run(context, semanticInitFailure));
