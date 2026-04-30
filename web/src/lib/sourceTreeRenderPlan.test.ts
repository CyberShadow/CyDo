import { describe, it, expect } from "vitest";
import { parseCommandSourceTree } from "./sourceTree";
import {
  classifyEmbedRenderMode,
  isLineBoundaryEmbed,
} from "./sourceTreeRenderPlan";

describe("source tree render plan", () => {
  it("isLineBoundaryEmbed returns false for quoted wrapper payload", () => {
    const command =
      "/run/current-system/sw/bin/zsh -lc 'program --some-flag -y \"hello world\"'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;

    expect(isLineBoundaryEmbed(parsed.value.text, wrapper.span)).toBe(false);
    expect(classifyEmbedRenderMode(parsed.value, wrapper)).toBe("inline");
  });

  it("isLineBoundaryEmbed returns true for heredoc body spans", () => {
    const command = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const heredoc = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;

    expect(isLineBoundaryEmbed(parsed.value.text, heredoc.span)).toBe(true);
  });

  it("classifies heredoc body as rich markdown in safe heredoc context", () => {
    const command = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const heredoc = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc) return;

    expect(classifyEmbedRenderMode(parsed.value, heredoc)).toBe(
      "rich-markdown",
    );
  });

  it("does not promote non-heredoc embeds to rich", () => {
    const command = "/run/current-system/sw/bin/zsh -lc 'cat README.md'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = parsed.value.segments.find(
      (segment) => segment.kind === "embed",
    );
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;

    expect(classifyEmbedRenderMode(parsed.value, wrapper)).toBe("inline");
  });
});
