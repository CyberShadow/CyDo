import type { TaskTypeInfo } from "../useSessionManager";

import blankIcon from "../icons/blank.svg?raw";
import conversationIcon from "../icons/conversation.svg?raw";
import planModeIcon from "../icons/plan-mode.svg?raw";
import bugModeIcon from "../icons/bug-mode.svg?raw";
import writeModeIcon from "../icons/write-mode.svg?raw";
import planIcon from "../icons/plan.svg?raw";
import quickResearchIcon from "../icons/quick-research.svg?raw";
import researchIcon from "../icons/research.svg?raw";
import bugIcon from "../icons/bug.svg?raw";
import reproduceIcon from "../icons/reproduce.svg?raw";
import spikeIcon from "../icons/spike.svg?raw";
import testIcon from "../icons/test.svg?raw";
import triageIcon from "../icons/triage.svg?raw";
import decomposeIcon from "../icons/decompose.svg?raw";
import implementIcon from "../icons/implement.svg?raw";
import verifyIcon from "../icons/verify.svg?raw";
import reviewIcon from "../icons/review.svg?raw";
import stewardQualityIcon from "../icons/steward-quality.svg?raw";
import stewardSecurityIcon from "../icons/steward-security.svg?raw";
import checkIcon from "../icons/check.svg?raw";
import dotIcon from "../icons/dot.svg?raw";
import plusIcon from "../icons/plus.svg?raw";
import questionIcon from "../icons/question.svg?raw";
import archiveIcon from "../icons/archive.svg?raw";

const rawIcons: Record<string, string> = {
  check: checkIcon,
  dot: dotIcon,
  plus: plusIcon,
  question: questionIcon,
  archive: archiveIcon,
  blank: blankIcon,
  conversation: conversationIcon,
  "plan-mode": planModeIcon,
  "bug-mode": bugModeIcon,
  "write-mode": writeModeIcon,
  plan: planIcon,
  "quick-research": quickResearchIcon,
  research: researchIcon,
  bug: bugIcon,
  reproduce: reproduceIcon,
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

/** Convert raw SVG to a CSS data URI for mask-image. */
function toMaskUri(raw: string): string {
  const mask = raw.replace(/currentColor/g, "black");
  return `url("data:image/svg+xml,${encodeURIComponent(mask)}")`;
}

// Inject a <style> element with one class per icon type, so the mask-image
// data URI is parsed once per icon type rather than once per element.
let styleInjected = false;
export function ensureIconStyles() {
  if (styleInjected) return;
  styleInjected = true;
  const rules = Object.entries(rawIcons)
    .map(([name, raw]) => {
      const uri = toMaskUri(raw);
      return `.task-type-icon-${CSS.escape(name)}{mask-image:${uri};-webkit-mask-image:${uri}}`;
    })
    .join("\n");
  const style = document.createElement("style");
  style.textContent = rules;
  document.head.appendChild(style);
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

  ensureIconStyles();

  return (
    <span
      class={`task-type-icon task-type-icon-${iconName}${className ? ` ${className}` : ""}`}
    />
  );
}
