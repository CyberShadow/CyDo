import { useState, useMemo, useEffect } from "preact/hooks";
import type { DisplayMessage } from "../types";
import { useHighlight, renderTokens } from "../highlight";
import { CopyButton } from "./CopyButton";
import editIcon from "../icons/edit.svg?raw";

function jsonReplacer(_key: string, value: unknown) {
  return value instanceof Map
    ? (Object.fromEntries(value) as Record<string, unknown>)
    : value;
}

function HighlightedJson({ text }: { text: string }) {
  const tokens = useHighlight(text, "json");
  return (
    <div class="code-pre-wrap">
      <CopyButton text={text} />
      <pre>
        {tokens
          ? tokens.map((line, i) => (
              <span key={i}>
                {i > 0 && "\n"}
                {renderTokens(line)}
              </span>
            ))
          : text}
      </pre>
    </div>
  );
}

function RawEventBlock({
  text,
  seq,
  onEditRaw,
}: {
  text: string;
  seq: number;
  onEditRaw?: (seq: number, content: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState("");
  const tokens = useHighlight(editing ? null : text, "json");

  return (
    <div class="code-pre-wrap">
      {!editing && (
        <>
          <CopyButton text={text} />
          {onEditRaw != null && (
            <button
              class="msg-action-btn edit-btn"
              onClick={() => {
                setEditText(text);
                setEditing(true);
              }}
              title="Edit raw event"
            >
              <span
                class="action-icon"
                dangerouslySetInnerHTML={{ __html: editIcon }}
              />
            </button>
          )}
          <pre>
            {tokens
              ? tokens.map((line, i) => (
                  <span key={i}>
                    {i > 0 && "\n"}
                    {renderTokens(line)}
                  </span>
                ))
              : text}
          </pre>
        </>
      )}
      {editing && (
        <>
          <textarea
            class="edit-textarea raw-edit-textarea"
            value={editText}
            onInput={(e) => {
              setEditText((e.target as HTMLTextAreaElement).value);
            }}
            onKeyDown={(e) => {
              if (e.key === "Escape") setEditing(false);
              else if (e.key === "Enter" && e.ctrlKey) {
                e.preventDefault();
                onEditRaw!(seq, editText);
                setEditing(false);
              }
            }}
            ref={(el) => el?.focus()}
          />
          <div class="edit-actions">
            <button
              class="btn btn-sm"
              onClick={() => {
                setEditing(false);
              }}
            >
              Cancel
            </button>
            <button
              class="btn btn-sm btn-primary"
              onClick={() => {
                onEditRaw!(seq, editText);
                setEditing(false);
              }}
            >
              Save
            </button>
          </div>
        </>
      )}
    </div>
  );
}

export function SourceView({
  msg,
  tid,
  onEditRaw,
}: {
  msg: DisplayMessage;
  tid: number;
  onEditRaw?: (seq: number, content: string) => void;
}) {
  const hasRaw = msg.seq != null;
  const [tab, setTab] = useState<"raw" | "agnostic">(
    hasRaw ? "raw" : "agnostic",
  );
  const [rawSources, setRawSources] = useState<unknown[] | null>(null);
  const [loading, setLoading] = useState(false);

  const seqs = useMemo(
    () => (msg.seq == null ? [] : Array.isArray(msg.seq) ? msg.seq : [msg.seq]),
    [msg.seq],
  );

  useEffect(() => {
    if (seqs.length === 0) return;
    setLoading(true);
    Promise.all(
      seqs.map((s) =>
        fetch(`/api/raw-source?tid=${tid}&seq=${s}`).then((r) => r.json()),
      ),
    )
      .then((results) => {
        setRawSources(results);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, [tid, msg.seq]);

  const agnosticText = useMemo(
    () => JSON.stringify(msg.rawSource ?? msg, jsonReplacer, 2),
    [msg.rawSource ?? msg],
  );

  return (
    <div class="message source-view">
      {hasRaw && (
        <div class="source-tabs">
          <button
            class={`source-tab${tab === "raw" ? " active" : ""}`}
            onClick={() => {
              setTab("raw");
            }}
          >
            Raw
          </button>
          <button
            class={`source-tab${tab === "agnostic" ? " active" : ""}`}
            onClick={() => {
              setTab("agnostic");
            }}
          >
            Agnostic
          </button>
        </div>
      )}
      {tab === "raw" && loading && <div class="source-loading">Loading...</div>}
      {tab === "raw" && rawSources && (
        <div class="raw-events">
          {rawSources.map((source, i) => (
            <RawEventBlock
              key={seqs[i]}
              text={JSON.stringify(source, jsonReplacer, 2)}
              seq={seqs[i]!}
              onEditRaw={onEditRaw}
            />
          ))}
        </div>
      )}
      {tab === "agnostic" && <HighlightedJson text={agnosticText} />}
    </div>
  );
}
