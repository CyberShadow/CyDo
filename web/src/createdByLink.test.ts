import { describe, expect, it } from "vitest";
import { createdByLink } from "./createdByLink";

describe("createdByLink", () => {
  const getByTid = (tid: number) =>
    tid === 7 ? { title: "Creator" } : undefined;
  const getTaskHref = (id: string) => `/task/${id}`;

  it("omits the link when a task has no creator", () => {
    expect(createdByLink({}, getByTid, getTaskHref)).toBeUndefined();
  });

  it("links to the creator and includes its title when known", () => {
    expect(createdByLink({ creatorTid: 7 }, getByTid, getTaskHref)).toEqual({
      href: "/task/7",
      tid: 7,
      title: "Creator",
    });
    expect(createdByLink({ creatorTid: 8 }, getByTid, getTaskHref)).toEqual({
      href: "/task/8",
      tid: 8,
      title: undefined,
    });
  });
});
