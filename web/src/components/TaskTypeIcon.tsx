import { h } from "preact";
import type { TaskTypeInfo } from "../useSessionManager";

import blankIcon from "../icons/blank.svg";
import conversationIcon from "../icons/conversation.svg";
import planModeIcon from "../icons/plan-mode.svg";
import bugModeIcon from "../icons/bug-mode.svg";
import writeModeIcon from "../icons/write-mode.svg";
import planIcon from "../icons/plan.svg";
import researchIcon from "../icons/research.svg";
import bugIcon from "../icons/bug.svg";
import spikeIcon from "../icons/spike.svg";
import testIcon from "../icons/test.svg";
import triageIcon from "../icons/triage.svg";
import decomposeIcon from "../icons/decompose.svg";
import implementIcon from "../icons/implement.svg";
import verifyIcon from "../icons/verify.svg";
import reviewIcon from "../icons/review.svg";
import stewardQualityIcon from "../icons/steward-quality.svg";
import stewardSecurityIcon from "../icons/steward-security.svg";

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
  const iconUrl = iconName ? iconMap[iconName] : undefined;

  if (!iconUrl) return null;

  return (
    <span
      class={`task-type-icon${className ? ` ${className}` : ""}`}
      style={{
        maskImage: `url(${iconUrl})`,
        WebkitMaskImage: `url(${iconUrl})`,
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}
