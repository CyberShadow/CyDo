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

const iconMap: Record<string, string> = {
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
  const svgMarkup = iconName ? iconMap[iconName] : undefined;

  if (!svgMarkup) return null;

  return (
    <span
      class={`task-type-icon${className ? ` ${className}` : ""}`}
      dangerouslySetInnerHTML={{ __html: svgMarkup }}
    />
  );
}
