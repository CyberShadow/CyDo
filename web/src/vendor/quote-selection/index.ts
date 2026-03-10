// Vendored from https://github.com/github/quote-selection (MIT license)

import { extractFragment, insertMarkdownSyntax } from "./markdown";

class Quote {
  selection = window.getSelection();

  get range(): Range {
    return this.selection?.rangeCount
      ? this.selection.getRangeAt(0)
      : new Range();
  }

  get selectionText(): string {
    return this.selection?.toString().trim() || "";
  }

  get quotedText(): string {
    return `> ${this.selectionText.replace(/\n/g, "\n> ")}\n\n`;
  }
}

export class MarkdownQuote extends Quote {
  get selectionText() {
    if (!this.selection) return "";
    const fragment = extractFragment(this.range, "");
    insertMarkdownSyntax(fragment);
    const body = document.body;
    if (!body) return "";

    const div = document.createElement("div");
    div.appendChild(fragment);
    div.style.cssText = "position:absolute;left:-9999px;";
    body.appendChild(div);
    let selectionText = "";
    try {
      const range = document.createRange();
      range.selectNodeContents(div);
      this.selection.removeAllRanges();
      this.selection.addRange(range);
      selectionText = this.selection.toString();
      this.selection.removeAllRanges();
      range.detach();
    } finally {
      body.removeChild(div);
    }
    return selectionText.trim();
  }
}
