import { expect, it } from "vitest";
import { classifyLinkTarget } from "./localFileLinks";

it.each([
  ["/abs/a.png", null, "/abs/a.png"],
  ["rel/a.md", "/w", "/w/rel/a.md"],
  ["../x", "/w/docs", "/w/x"],
  ["./x", "/w", "/w/x"],
  ["../../x", "/w", "/x"],
  ["src/app.d:42", "/w", "/w/src/app.d"],
  ["app.d:42:7", "/w", "/w/app.d"],
  ["x.md#L12", "/w", "/w/x.md"],
  ["x.md#heading", "/w", "/w/x.md"],
  ["file:///tmp/a%20b.png", null, "/tmp/a b.png"],
  ["file://localhost/x", null, "/x"],
  ["/tmp/a b.png", null, "/tmp/a b.png"],
  ["/tmp/a%20b.png", null, "/tmp/a%20b.png"],
])("resolves %s with working directory %s to %s", (url, baseDir, path) => {
  expect(classifyLinkTarget(url, baseDir)).toEqual({ kind: "local", path });
});

it.each([
  "#top",
  "https://example.org/x",
  "https://example.com:8080",
  "mailto:user@example.org",
  "tel:123",
  "//example.org/x",
])("keeps %s as a web destination", (url) => {
  expect(classifyLinkTarget(url, "/w")).toEqual({ kind: "web" });
});

it.each([
  ["file://other/x", "file URL names another host"],
  ["file:///50%.png", "malformed file URL"],
  ["relative.md", "relative path; the working directory is not known"],
  ["", "empty path"],
])("reports %j as unresolved without a working directory", (url, reason) => {
  expect(classifyLinkTarget(url, null)).toEqual({ kind: "unresolved", reason });
});

it.each(["", "relative"])(
  "rejects a nonabsolute base directory %j",
  (baseDir) => {
    expect(() => classifyLinkTarget("notes.md", baseDir)).toThrow(
      "A local file base directory must be absolute",
    );
  },
);
