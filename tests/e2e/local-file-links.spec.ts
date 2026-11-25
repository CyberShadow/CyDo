import { writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assistantText,
  enterSession,
  expect,
  sendMessage,
  test,
} from "./fixtures";

const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==";

test(
  "Local Markdown links expand inline and open live in the file viewer",
  { tag: "@claude-only" },
  async ({ page, backend }) => {
    const screenshotPath = join(backend.wsDir, "shot.png");
    const notesPath = join(backend.wsDir, "linked.md");
    writeFileSync(screenshotPath, Buffer.from(png, "base64"));
    writeFileSync(notesPath, "# First heading\n");

    await enterSession(page);
    await sendMessage(
      page,
      `reply with "- ![shot](${screenshotPath})\n- [notes](linked.md)"`,
    );

    const reply = assistantText(page, "notes");
    const shot = reply.getByRole("listitem").filter({
      has: page.getByRole("button", {
        name: `Collapse ${screenshotPath}`,
        exact: true,
      }),
    });
    const shotPanel = shot.locator(".local-file-expansion");
    await shotPanel.scrollIntoViewIfNeeded();
    const image = shotPanel.locator("img.tool-result-image");
    await expect(image).toHaveAttribute("src", /^data:image\/png;base64,/);
    await expect(image).toHaveJSProperty("naturalWidth", 1);

    const notes = reply.getByRole("listitem").filter({
      has: page.getByText("notes", { exact: true }),
    });
    const notesPanel = notes.locator(".local-file-expansion");
    const expandNotes = notes.getByRole("button", {
      name: `Expand ${notesPath}`,
      exact: true,
    });
    await expect(expandNotes).toHaveAttribute("aria-expanded", "false");
    await expect(notesPanel).toHaveCount(0);
    await expandNotes.click();
    await notesPanel.scrollIntoViewIfNeeded();
    const firstHeading = { name: "First heading", level: 1, exact: true };
    await expect(notesPanel.getByRole("heading", firstHeading)).toBeVisible();

    await notes
      .getByRole("button", {
        name: `Open ${notesPath} in the file viewer`,
        exact: true,
      })
      .click();
    const viewer = page.locator(".file-viewer");
    await expect(
      viewer.getByRole("button", { name: "Live", exact: true }),
    ).toHaveClass(/\bactive\b/);
    await expect(
      viewer.locator(".content-viewer-body").getByRole("heading", firstHeading),
    ).toBeVisible();

    writeFileSync(notesPath, "# Second heading\n");
    await viewer.getByRole("button", { name: "Close", exact: true }).click();
    await notes
      .getByRole("button", { name: `Collapse ${notesPath}`, exact: true })
      .click();
    await expect(notesPanel).toHaveCount(0);
    await expandNotes.click();
    await notesPanel.scrollIntoViewIfNeeded();
    await expect(
      notesPanel.getByRole("heading", {
        name: "Second heading",
        level: 1,
        exact: true,
      }),
    ).toBeVisible();
  },
);
