import { describe, expect, it } from "vitest";
import {
  prepareEmbedProjection,
  type SourceProjection,
  type SourceSegment,
} from "./sourceTree";

describe("sourceTree projection helpers", () => {
  it("returns null for malformed projections and invalid offsets", () => {
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

    const embed = {
      kind: "embed",
      span: { start: 4, end: 5 },
      content: { language: "bash", text: "a", segments: [] },
      origin: { language: "bash", construct: "test", attributes: {} },
      projection: {
        points: [
          { child: 0, parent: 0 },
          { child: 1, parent: 1 },
        ],
      },
    } satisfies SourceSegment;
    for (const projection of [
      malformedStart,
      malformedOrder,
      malformedPlateau,
    ]) {
      expect(prepareEmbedProjection({ ...embed, projection })).toBeNull();
    }
    const project = prepareEmbedProjection(embed)!();
    expect(project(0)).toBe(4);
    expect(project(1)).toBe(5);
    expect(project(2)).toBeNull();
    expect(project(0.5)).toBeNull();
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

    const project = prepareEmbedProjection(embed)!();
    expect([0, 1, 2, 3, 4].map(project)).toEqual([4, 5, 6, 8, null]);
  });
});
