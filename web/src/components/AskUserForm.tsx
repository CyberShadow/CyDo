import { useState } from "preact/hooks";
import type { AskUserQuestionItem } from "../protocol";
import { Markdown } from "./Markdown";

interface Props {
  questions: AskUserQuestionItem[];
  onSubmit: (answers: Record<string, string>) => void;
  onAbort: () => void;
}

export function AskUserForm({ questions, onSubmit, onAbort }: Props) {
  // For each question index: selected option labels (or empty if using custom)
  const [selections, setSelections] = useState<Map<number, Set<string>>>(
    () => new Map(questions.map((_, i) => [i, new Set<string>()])),
  );
  const [customTexts, setCustomTexts] = useState<Map<number, string>>(
    () => new Map(questions.map((_, i) => [i, ""])),
  );
  const [useCustom, setUseCustom] = useState<Map<number, boolean>>(
    () => new Map(questions.map((_, i) => [i, false])),
  );

  const toggleOption = (qi: number, label: string, multiSelect: boolean) => {
    setSelections((prev) => {
      const next = new Map(prev);
      const set = new Set(next.get(qi) ?? []);
      if (multiSelect) {
        if (set.has(label)) set.delete(label);
        else set.add(label);
      } else {
        set.clear();
        set.add(label);
        // Deselect "Other" only for single-select
        setUseCustom((prev) => {
          const next = new Map(prev);
          next.set(qi, false);
          return next;
        });
      }
      next.set(qi, set);
      return next;
    });
  };

  const handleSubmit = () => {
    const answers: Record<string, string> = {};
    for (let qi = 0; qi < questions.length; qi++) {
      const q = questions[qi]!;
      const selected = Array.from(selections.get(qi) ?? []);
      const custom = useCustom.get(qi) ? (customTexts.get(qi) ?? "") : "";
      const parts = [...selected];
      if (custom) parts.push(custom);
      answers[q.question] = parts.join(", ");
    }
    onSubmit(answers);
  };

  const hasAnyAnswer = questions.some((_, qi) => {
    const hasSelection = (selections.get(qi)?.size ?? 0) > 0;
    const hasCustom =
      useCustom.get(qi) && (customTexts.get(qi) ?? "").length > 0;
    return hasSelection || hasCustom;
  });

  return (
    <div class="ask-user-form">
      {questions.map((q, qi) => (
        <div key={qi} class="ask-user-form-question">
          <div class="ask-question-header">{q.header}</div>
          <Markdown text={q.question} class="ask-question-text" />
          <div class="ask-options-interactive">
            {q.options.map((opt, oi) => {
              const selected = selections.get(qi)?.has(opt.label) ?? false;
              return (
                <button
                  key={oi}
                  class={`ask-option-btn ${selected ? "selected" : ""}`}
                  onClick={() => {
                    toggleOption(qi, opt.label, q.multiSelect ?? false);
                  }}
                >
                  <span class="ask-option-label">{opt.label}</span>
                  {opt.description && (
                    <Markdown text={opt.description} class="ask-option-desc" />
                  )}
                </button>
              );
            })}
            <button
              class={`ask-option-btn other ${
                useCustom.get(qi) ? "selected" : ""
              }`}
              onClick={() => {
                const isMulti = q.multiSelect ?? false;
                setUseCustom((prev) => {
                  const next = new Map(prev);
                  const wasCustom = prev.get(qi) ?? false;
                  next.set(qi, isMulti ? !wasCustom : true);
                  return next;
                });
                if (!isMulti) {
                  // Single-select: clear option selections
                  setSelections((prev) => {
                    const next = new Map(prev);
                    next.set(qi, new Set());
                    return next;
                  });
                }
              }}
            >
              Other
            </button>
            {useCustom.get(qi) && (
              <textarea
                class="ask-custom-input"
                placeholder="Type your answer..."
                value={customTexts.get(qi) ?? ""}
                onInput={(e) => {
                  const val = (e.target as HTMLTextAreaElement).value;
                  setCustomTexts((prev) => {
                    const next = new Map(prev);
                    next.set(qi, val);
                    return next;
                  });
                }}
                autoFocus
              />
            )}
          </div>
        </div>
      ))}
      <div class="ask-submit-row">
        <button class="ask-abort-btn" onClick={onAbort}>
          Dismiss
        </button>
        <button
          class="ask-submit-btn"
          disabled={!hasAnyAnswer}
          onClick={handleSubmit}
        >
          Submit
        </button>
      </div>
    </div>
  );
}
