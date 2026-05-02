import { describe, expect, it } from "vitest";
import {
  projectDescendantSpan,
  projectEmbedSpan,
  projectOffset,
  projectSpan,
  type SourceNode,
  type SourceProjection,
  type SourceSegment,
} from "./sourceTree";

describe("sourceTree projection helpers", () => {
  it("returns null for malformed projections and invalid spans", () => {
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
  });

  it("projects embedded spans through explicit projections", () => {
    const embed: Extract<SourceSegment, { kind: "embed" }> = {
      kind: "embed",
      span: { start: 4, end: 8 },
      projection: {
        points: [
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
          { child: 2, parent: 2 },
          { child: 3, parent: 4 },
        ],
      },
      content: {
        language: "bash",
        text: 'a"b',
        segments: [{ kind: "text", span: { start: 0, end: 3 } }],
      },
      origin: {
        language: "bash",
        construct: "command-wrapper-payload",
        attributes: { quote: "projected" },
      },
    };

    expect(projectEmbedSpan(embed, { start: 0, end: 1 })).toEqual({
      start: 4,
      end: 5,
    });
    expect(projectEmbedSpan(embed, { start: 1, end: 2 })).toEqual({
      start: 5,
      end: 6,
    });
    expect(projectEmbedSpan(embed, { start: 0, end: 4 })).toBeNull();
  });

  it("projects descendant spans through nested embed paths", () => {
    const root: SourceNode = {
      language: "bash",
      text: "xxabcyy",
      segments: [
        { kind: "text", span: { start: 0, end: 2 } },
        {
          kind: "embed",
          span: { start: 2, end: 5 },
          origin: {
            language: "bash",
            construct: "command-wrapper-payload",
            attributes: { quote: "double" },
          },
          content: {
            language: "bash",
            text: "abc",
            segments: [{ kind: "text", span: { start: 0, end: 3 } }],
          },
        },
        { kind: "text", span: { start: 5, end: 7 } },
      ],
    };

    const projected = projectDescendantSpan(root, [1], { start: 1, end: 3 });
    expect(projected).toEqual({ start: 3, end: 5 });
    expect(root.text.slice(projected!.start, projected!.end)).toBe("bc");
  });
});
