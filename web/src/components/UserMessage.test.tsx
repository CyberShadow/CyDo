import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { UserMessage } from "./UserMessage";
import type { DisplayMessage } from "../types";

function render(message: DisplayMessage) {
  return renderToString(<UserMessage message={message} />);
}

function userMessage(
  content: DisplayMessage["content"],
  extra: Partial<DisplayMessage> = {},
): DisplayMessage {
  return { id: "user", type: "user", content, ...extra };
}

describe("UserMessage multipart text rendering", () => {
  it("renders one user box for each text entry in source order", () => {
    const html = render(
      userMessage([
        { type: "text", text: "first entry" },
        { type: "text", text: "second entry" },
        { type: "text", text: "third entry" },
      ]),
    );

    expect(html.match(/class="message user-message(?:[^"]*)"/g)).toHaveLength(
      1,
    );
    expect(html.match(/class="user-content-item"/g)).toHaveLength(3);
    expect(html).toContain('<div class="user-text">first entry</div>');
    expect(html).toContain('<div class="user-text">second entry</div>');
    expect(html).toContain('<div class="user-text">third entry</div>');
    expect(html.indexOf("first entry")).toBeLessThan(
      html.indexOf("second entry"),
    );
    expect(html.indexOf("second entry")).toBeLessThan(
      html.indexOf("third entry"),
    );
  });

  it("keeps a singleton text entry in one ordinary user box", () => {
    const html = render(userMessage([{ type: "text", text: "only entry" }]));

    expect(html.match(/class="message user-message(?:[^"]*)"/g)).toHaveLength(
      1,
    );
    expect(html).toContain('<div class="user-text">only entry</div>');
  });

  it.each([
    ["synthetic", { isSynthetic: true }],
    ["tool-result child", { parentToolUseId: "tool-1" }],
    ["compact summary", { isCompactSummary: true }],
  ] as const)(
    "renders every %s text entry with markdown semantics",
    (_, extra) => {
      const html = render(
        userMessage(
          [
            { type: "text", text: "**first**" },
            { type: "text", text: "**second**" },
          ],
          extra,
        ),
      );

      expect(html.match(/class="user-content-item"/g)).toHaveLength(2);
      expect(html).toContain("<strong>first</strong>");
      expect(html).toContain("<strong>second</strong>");
      expect(html).not.toContain('class="user-text"');
    },
  );

  it("keeps empty text entries as empty user boxes", () => {
    const html = render(
      userMessage([
        { type: "text", text: "" },
        { type: "text", text: "middle" },
        { type: "text", text: "" },
      ]),
    );

    expect(html.match(/class="user-content-item"/g)).toHaveLength(3);
    expect(html).toContain('<div class="user-text"></div>');
    expect(html).toContain('<div class="user-text">middle</div>');
  });

  it("owns attachments and badges on the first text entry only", () => {
    const html = render(
      userMessage(
        [
          { type: "text", text: "with attachment" },
          {
            type: "image",
            data: "YWJj",
            media_type: "image/png",
          },
          { type: "text", text: "without attachment" },
        ],
        { isMeta: true },
      ),
    );

    const items = html.split('class="user-content-item"');
    expect(items).toHaveLength(3);
    const [, firstItem, secondItem] = items;
    expect(html.match(/class="user-images"/g)).toHaveLength(1);
    expect(
      html.match(/<span class="meta-badge meta">meta<\/span>/g),
    ).toHaveLength(1);
    expect(firstItem).not.toContain("user-images");
    expect(firstItem).not.toContain("meta-badge meta");
    expect(secondItem).not.toContain("user-images");
    expect(secondItem).not.toContain("meta-badge meta");
  });

  it("renders raw kind badges in order once for a multipart meta message", () => {
    const html = render(
      userMessage(
        [
          { type: "text", text: "plugin recommendations" },
          { type: "text", text: "agent instructions" },
        ],
        {
          isMeta: true,
          metaKinds: ["plugins.recommendations", "agents_md.instructions"],
        },
      ),
    );

    expect(
      html.match(/<span class="meta-badge meta meta-kind">[^<]*<\/span>/g),
    ).toEqual([
      '<span class="meta-badge meta meta-kind">plugins.recommendations</span>',
      '<span class="meta-badge meta meta-kind">agents_md.instructions</span>',
    ]);
    expect(html).not.toContain(">meta<");
  });
});
