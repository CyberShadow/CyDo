import { h } from "preact";
import type { TaskTypeInfo } from "../useSessionManager";

import blankIcon from "../icons/blank.svg?raw";
import conversationIcon from "../icons/conversation.svg?raw";
import planModeIcon from "../icons/plan-mode.svg?raw";
import bugModeIcon from "../icons/bug-mode.svg?raw";
import writeModeIcon from "../icons/write-mode.svg?raw";
import planIcon from "../icons/plan.svg?raw";
import researchIcon from "../icons/research.svg?raw";
import bugIcon from "../icons/bug.svg?raw";
import spikeIcon from "../icons/spike.svg?raw";
import testIcon from "../icons/test.svg?raw";
import triageIcon from "../icons/triage.svg?raw";
import decomposeIcon from "../icons/decompose.svg?raw";
import implementIcon from "../icons/implement.svg?raw";
import verifyIcon from "../icons/verify.svg?raw";
import reviewIcon from "../icons/review.svg?raw";
import stewardQualityIcon from "../icons/steward-quality.svg?raw";
import stewardSecurityIcon from "../icons/steward-security.svg?raw";

const rawIcons: Record<string, string> = {
  blank: blankIcon,
  conversation: conversationIcon,
  "plan-mode": planModeIcon,
  "bug-mode": bugModeIcon,
  "write-mode": writeModeIcon,
  plan: planIcon,
  research: researchIcon,
  bug: bugIcon,
  spike: spikeIcon,
  test: testIcon,
  triage: triageIcon,
  decompose: decomposeIcon,
  implement: implementIcon,
  verify: verifyIcon,
  review: reviewIcon,
  "steward-quality": stewardQualityIcon,
  "steward-security": stewardSecurityIcon,
};

/** Parse raw SVG string into a <symbol> element, rewriting internal ids to avoid collisions. */
function svgToSymbol(name: string, raw: string): string {
  const parser = new DOMParser();
  const doc = parser.parseFromString(raw, "image/svg+xml");
  const svg = doc.documentElement;
  const viewBox = svg.getAttribute("viewBox") || "0 0 16 16";

  // Rewrite id attributes and their url(#id) references to be unique per symbol
  const prefix = `icon-${name}-`;
  const idMap = new Map<string, string>();
  svg.querySelectorAll("[id]").forEach((el) => {
    const oldId = el.getAttribute("id")!;
    const newId = prefix + oldId;
    idMap.set(oldId, newId);
    el.setAttribute("id", newId);
  });
  if (idMap.size > 0) {
    const refAttrs = ["mask", "clip-path", "fill", "stroke", "filter"];
    svg.querySelectorAll("*").forEach((el) => {
      for (const attr of refAttrs) {
        const val = el.getAttribute(attr);
        if (val) {
          const replaced = val.replace(/url\(#([^)]+)\)/g, (_, id) => {
            const newId = idMap.get(id);
            return newId ? `url(#${newId})` : `url(#${id})`;
          });
          if (replaced !== val) el.setAttribute(attr, replaced);
        }
      }
    });
  }

  // Copy presentational attributes from <svg> to <symbol>
  const presentAttrs = [
    "fill",
    "stroke",
    "stroke-width",
    "stroke-linecap",
    "stroke-linejoin",
  ];
  const attrStr = presentAttrs
    .map((a) => {
      const v = svg.getAttribute(a);
      return v ? `${a}="${v}"` : "";
    })
    .filter(Boolean)
    .join(" ");

  return `<symbol id="icon-${name}" viewBox="${viewBox}"${attrStr ? " " + attrStr : ""}>${svg.innerHTML}</symbol>`;
}

let spriteInjected = false;

/** Inject a single hidden SVG sprite sheet into the document. */
function ensureSpriteSheet() {
  if (spriteInjected) return;
  spriteInjected = true;

  const symbols = Object.entries(rawIcons)
    .map(([name, raw]) => svgToSymbol(name, raw))
    .join("\n");

  const sprite = document.createElement("div");
  sprite.style.display = "none";
  sprite.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg">${symbols}</svg>`;
  document.body.prepend(sprite);
}

interface TaskTypeIconProps {
  taskType?: string;
  taskTypes: TaskTypeInfo[];
  class?: string;
}

export function TaskTypeIcon({
  taskType,
  taskTypes,
  class: className,
}: TaskTypeIconProps) {
  const typeInfo = taskTypes.find((tt) => tt.name === taskType);
  const iconName = typeInfo?.icon;

  if (!iconName || !rawIcons[iconName]) return null;

  ensureSpriteSheet();

  return (
    <span class={`task-type-icon${className ? ` ${className}` : ""}`}>
      <svg viewBox="0 0 16 16">
        <use href={`#icon-${iconName}`} />
      </svg>
    </span>
  );
}
