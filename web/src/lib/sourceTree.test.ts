import { describe, expect, it } from "vitest";
import {
  parseCommandSourceTree,
  projectDescendantSpan,
  projectEmbedSpan,
  projectOffset,
  projectSpan,
  type SourceProjection,
  type SourceSegment,
} from "./sourceTree";

function findFirstEmbed(
  segments: SourceSegment[],
): Extract<SourceSegment, { kind: "embed" }> | null {
  return (
    segments.find(
      (segment): segment is Extract<SourceSegment, { kind: "embed" }> =>
        segment.kind === "embed",
    ) ?? null
  );
}

describe("sourceTree projection parser", () => {
  it("parses at least three nested shell wrapper levels", () => {
    const command = 'zsh -lc "bash -lc \'sh -c \\"cat README.md\\"\'"';
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const level1 = findFirstEmbed(parsed.value.segments);
    expect(level1).not.toBeNull();
    if (!level1) return;
    const level2 = findFirstEmbed(level1.content.segments);
    expect(level2).not.toBeNull();
    if (!level2) return;
    const level3 = findFirstEmbed(level2.content.segments);
    expect(level3).not.toBeNull();
    if (!level3) return;

    expect(parsed.value.language).toBe("bash");
    expect(level1.content.language).toBe("bash");
    expect(level2.content.language).toBe("bash");
    expect(level3.content.language).toBe("bash");
    expect(level3.content.text).toBe("cat README.md");
    expect(parsed.value.text).toBe(command);
  });

  it("preserves raw escaped double-quote payload text and projects decoded quote spans", () => {
    const command = 'zsh -lc "echo \\"CYDO_SKIP_LOAD_TASKS\\""';
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper || !wrapper.projection) return;

    expect(parsed.value.text).toBe(command);
    expect(parsed.value.text).toContain('\\"CYDO_SKIP_LOAD_TASKS\\"');
    expect(wrapper.content.text).toBe('echo "CYDO_SKIP_LOAD_TASKS"');

    const quote = wrapper.content.text.indexOf('"CYDO_SKIP_LOAD_TASKS"');
    expect(quote).toBeGreaterThanOrEqual(0);
    if (quote < 0) return;

    const local = projectSpan(wrapper.projection, {
      start: quote,
      end: quote + 1,
    });
    expect(local).not.toBeNull();
    if (!local) return;

    const parentStart = wrapper.span.start + local.start;
    const parentEnd = wrapper.span.start + local.end;
    expect(parsed.value.text.slice(parentStart, parentEnd)).toBe('\\"');
  });

  it("preserves raw single-quote close/escape/reopen text and projects apostrophe spans", () => {
    const command = "zsh -lc 'printf '\\''hi'\\'''";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;

    expect(parsed.value.text).toContain("'\\''");
    expect(wrapper.content.text).toBe("printf 'hi'");
    expect(wrapper.content.text.includes("'")).toBe(true);

    const apostrophe = wrapper.content.text.indexOf("'");
    expect(apostrophe).toBeGreaterThanOrEqual(0);
    if (apostrophe < 0) return;

    const mapped = projectEmbedSpan(wrapper, {
      start: apostrophe,
      end: apostrophe + 1,
    });
    expect(mapped).not.toBeNull();
    if (!mapped) return;

    expect(parsed.value.text.slice(mapped.start, mapped.end)).toBe("'\\''");
  });

  it("parses mixed quoted wrapper payload words and preserves raw source with decoded heredoc body", () => {
    const command =
      "zsh -lc \"cat <<'EOF'\nheredoc body with \\\"quotes\\\" and \"'$literal\nEOF'";
    const parsed = parseCommandSourceTree(command);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapperIdx = parsed.value.segments.findIndex(
      (s) => s.kind === "embed",
    );
    expect(wrapperIdx).toBeGreaterThanOrEqual(0);
    if (wrapperIdx < 0) return;
    const wrapper = parsed.value.segments[wrapperIdx];
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper || wrapper.kind !== "embed") return;

    expect(wrapper.escaping.kind).toBe("shell-word");
    expect(wrapper.content.text).toBe(
      "cat <<'EOF'\nheredoc body with \"quotes\" and $literal\nEOF",
    );
    expect(parsed.value.text).toContain('\\"quotes\\" and "\'$literal');

    const heredocIdx = wrapper.content.segments.findIndex(
      (segment) => segment.kind === "embed",
    );
    expect(heredocIdx).toBeGreaterThanOrEqual(0);
    if (heredocIdx < 0) return;
    const heredoc = wrapper.content.segments[heredocIdx];
    expect(heredoc?.kind).toBe("embed");
    if (!heredoc || heredoc.kind !== "embed") return;
    expect(heredoc.content.text).toBe(
      'heredoc body with "quotes" and $literal',
    );

    const projected = projectDescendantSpan(
      parsed.value,
      [wrapperIdx, heredocIdx],
      { start: 0, end: heredoc.content.text.length },
    );
    expect(projected).not.toBeNull();
    if (!projected) return;
    expect(parsed.value.text.slice(projected.start, projected.end)).toContain(
      '\\"quotes\\" and "\'$literal',
    );
  });

  it("accepts adjacent quoted wrapper fragments as one payload word", () => {
    const parsed = parseCommandSourceTree("zsh -lc 'cat README.md''x'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper?.kind).toBe("embed");
    if (!wrapper) return;
    expect(wrapper.content.text).toBe("cat README.mdx");
  });

  it("rejects wrapper payload fragments split by whitespace as extra argv", () => {
    const parsed = parseCommandSourceTree("zsh -lc 'cat README.md' 'x'");
    expect(parsed.ok).toBe(false);
  });

  it("rejects unsafe wrapper payload syntax", () => {
    const bad = [
      'zsh -lc "cat $HOME/README.md"',
      'zsh -lc "cat `pwd`/README.md"',
      "zsh -lc cat*README.md",
      "zsh -lc cat;README.md",
      "zsh -lc cat|README.md",
      "zsh -lc cat>README.md",
      'bash -lc "echo ok" x',
    ];
    for (const command of bad) {
      const parsed = parseCommandSourceTree(command);
      expect(parsed.ok).toBe(false);
    }
  });

  it("parses shell/bash heredoc bodies recursively and keeps markdown/xml heredocs as text nodes", () => {
    const directBashCommand = "bash <<'EOF'\ncat README.md\nEOF";
    const directBashParsed = parseCommandSourceTree(directBashCommand);
    expect(directBashParsed.ok).toBe(true);
    if (!directBashParsed.ok) return;
    const directBashHeredoc = findFirstEmbed(directBashParsed.value.segments);
    expect(directBashHeredoc?.content.language).toBe("bash");

    const shellCommand =
      "cat > /tmp/a/script.sh <<'EOF'\nzsh -lc 'cat README.md'\nEOF";
    const shellParsed = parseCommandSourceTree(shellCommand);
    expect(shellParsed.ok).toBe(true);
    if (!shellParsed.ok) return;
    const shellHeredoc = findFirstEmbed(shellParsed.value.segments);
    expect(shellHeredoc?.kind).toBe("embed");
    if (!shellHeredoc) return;
    expect(shellHeredoc.content.language).toBe("bash");
    expect(findFirstEmbed(shellHeredoc.content.segments)?.kind).toBe("embed");

    const markdownCommand = "cat > /tmp/a/output.md <<'EOF'\n# Title\nEOF";
    const markdownParsed = parseCommandSourceTree(markdownCommand);
    expect(markdownParsed.ok).toBe(true);
    if (!markdownParsed.ok) return;
    const markdownHeredoc = findFirstEmbed(markdownParsed.value.segments);
    expect(markdownHeredoc?.content.language).toBe("markdown");
    expect(markdownHeredoc?.content.segments).toHaveLength(1);
    expect(markdownHeredoc?.content.segments[0]?.kind).toBe("text");

    const svgCommand = "cat > /tmp/a/output.svg <<'EOF'\n<svg></svg>\nEOF";
    const svgParsed = parseCommandSourceTree(svgCommand);
    expect(svgParsed.ok).toBe(true);
    if (!svgParsed.ok) return;
    const svgHeredoc = findFirstEmbed(svgParsed.value.segments);
    expect(svgHeredoc?.content.language).toBe("xml");
    expect(svgHeredoc?.content.segments).toHaveLength(1);
    expect(svgHeredoc?.content.segments[0]?.kind).toBe("text");
  });

  it("returns null (not exceptions) for invalid offsets and malformed projections", () => {
    const malformedStart: SourceProjection = {
      points: [
        { child: 1, parent: 0 },
        { child: 2, parent: 1 },
      ],
    };
    const malformedOrder: SourceProjection = {
      points: [
        { child: 0, parent: 0 },
        { child: 2, parent: 2 },
        { child: 1, parent: 3 },
      ],
    };
    const malformedPlateau: SourceProjection = {
      points: [
        { child: 0, parent: 0 },
        { child: 1, parent: 0 },
        { child: 2, parent: 1 },
      ],
    };

    expect(projectOffset(malformedStart, 1)).toBeNull();
    expect(projectOffset(malformedOrder, 1)).toBeNull();
    expect(projectOffset(malformedPlateau, 0)).toBeNull();
    expect(
      projectOffset(
        {
          points: [
            { child: 0, parent: 0 },
            { child: 1, parent: 1 },
          ],
        },
        2,
      ),
    ).toBeNull();
    expect(
      projectOffset(
        {
          points: [
            { child: 0, parent: 0 },
            { child: 1, parent: 1 },
          ],
        },
        0.5,
      ),
    ).toBeNull();
    expect(projectSpan(malformedStart, { start: 0, end: 1 })).toBeNull();
    expect(
      projectSpan(
        {
          points: [
            { child: 0, parent: 0 },
            { child: 1, parent: 1 },
          ],
        },
        { start: 0, end: 0.5 },
      ),
    ).toBeNull();
    expect(
      projectSpan(
        {
          points: [
            { child: 0, parent: 0 },
            { child: 1, parent: 1 },
          ],
        },
        { start: 2, end: 1 },
      ),
    ).toBeNull();

    const parsed = parseCommandSourceTree("zsh -lc 'cat README.md'");
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;

    expect(
      projectEmbedSpan(wrapper, {
        start: 0,
        end: wrapper.content.text.length + 1,
      }),
    ).toBeNull();
    expect(
      projectDescendantSpan(parsed.value, [999], { start: 0, end: 1 }),
    ).toBeNull();
    expect(
      projectDescendantSpan(parsed.value, [0], { start: 3, end: 2 }),
    ).toBeNull();

    const malformedProjectionWrapper: Extract<
      SourceSegment,
      { kind: "embed" }
    > = {
      ...wrapper,
      projection: {
        points: [
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
        ],
      },
    };
    expect(
      projectEmbedSpan(malformedProjectionWrapper, { start: 0, end: 1 }),
    ).toBeNull();
  });

  it("supports zero-length wrapper payload projections", () => {
    const parsed = parseCommandSourceTree('zsh -lc ""');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;

    const wrapper = findFirstEmbed(parsed.value.segments);
    expect(wrapper).not.toBeNull();
    if (!wrapper) return;
    expect(wrapper.content.text).toBe("");

    const mapped = projectEmbedSpan(wrapper, { start: 0, end: 0 });
    expect(mapped).not.toBeNull();
    if (!mapped) return;
    expect(mapped.start).toBe(wrapper.span.start);
    expect(mapped.end).toBe(wrapper.span.start);
  });
});
