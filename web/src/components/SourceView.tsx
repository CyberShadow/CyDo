import {
  useState,
  useMemo,
  useEffect,
  useRef,
  useCallback,
} from "preact/hooks";
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

/** Extract a short label from an event object for the collapsed header. */
function eventLabel(event: unknown): string {
  if (event == null || typeof event !== "object") return "event";
  const obj = event as Record<string, unknown>;
  // Use "type" field (e.g. "item/started", "turn/stop", "message_start")
  if (typeof obj.type === "string") return obj.type;
  return "event";
}

/** Extract a brief detail string (item_type, tool name, etc.) */
function eventDetail(event: unknown): string | null {
  if (event == null || typeof event !== "object") return null;
  const obj = event as Record<string, unknown>;
  const parts: string[] = [];
  if (typeof obj.item_type === "string") parts.push(obj.item_type);
  if (typeof obj.name === "string") parts.push(obj.name);
  return parts.length > 0 ? parts.join(" ") : null;
}

function EditableRawJson({
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
  const [preHeight, setPreHeight] = useState<number | undefined>(undefined);
  const preRef = useRef<HTMLPreElement>(null);
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
                if (preRef.current) {
                  setPreHeight(preRef.current.offsetHeight);
                }
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
          <pre ref={preRef}>
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
            style={preHeight != null ? { height: `${preHeight}px` } : undefined}
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

function EventItem({
  event,
  seq,
  tid,
  rawSource,
  onEditRaw,
}: {
  event: unknown;
  seq: number;
  tid: number;
  rawSource: unknown | null;
  onEditRaw?: (seq: number, content: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [tab, setTab] = useState<"abstract" | "raw">("abstract");
  const [rawData, setRawData] = useState<unknown | null>(rawSource);
  const [loading, setLoading] = useState(false);

  const label = eventLabel(event);
  const detail = eventDetail(event);

  const abstractText = useMemo(
    () => JSON.stringify(event, jsonReplacer, 2),
    [event],
  );

  const fetchRaw = useCallback(() => {
    if (rawData != null) return;
    setLoading(true);
    fetch(`/api/raw-source?tid=${tid}&seq=${seq}`)
      .then((r) => r.json())
      .then((data) => {
        setRawData(data);
        setLoading(false);
      })
      .catch(() => {
        setLoading(false);
      });
  }, [tid, seq, rawData]);

  const handleToggle = useCallback(() => {
    if (!expanded) {
      fetchRaw();
    }
    setExpanded(!expanded);
  }, [expanded, fetchRaw]);

  const rawText = useMemo(
    () => (rawData != null ? JSON.stringify(rawData, jsonReplacer, 2) : null),
    [rawData],
  );

  return (
    <div class="source-event">
      <div class="source-event-header" onClick={handleToggle}>
        <span class="source-event-chevron">
          {expanded ? "\u25BE" : "\u25B8"}
        </span>
        <span class="source-event-seq">{seq}</span>
        <span class="source-event-type">{label}</span>
        {detail && <span class="source-event-detail">{detail}</span>}
      </div>
      {expanded && (
        <div class="source-event-body">
          <div class="source-tabs">
            <button
              class={`source-tab${tab === "abstract" ? " active" : ""}`}
              onClick={() => {
                setTab("abstract");
              }}
            >
              Abstract
            </button>
            <button
              class={`source-tab${tab === "raw" ? " active" : ""}`}
              onClick={() => {
                setTab("raw");
                fetchRaw();
              }}
            >
              Raw
            </button>
          </div>
          {tab === "abstract" && <HighlightedJson text={abstractText} />}
          {tab === "raw" && loading && (
            <div class="source-loading">Loading...</div>
          )}
          {tab === "raw" && rawText && (
            <EditableRawJson text={rawText} seq={seq} onEditRaw={onEditRaw} />
          )}
        </div>
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
  const seqs = useMemo(
    () => (msg.seq == null ? [] : Array.isArray(msg.seq) ? msg.seq : [msg.seq]),
    [msg.seq],
  );

  // Build per-event list from rawSource
  const events: unknown[] = useMemo(() => {
    const raw = msg.rawSource;
    if (raw == null) return [];
    if (Array.isArray(raw)) return raw;
    return [raw];
  }, [msg.rawSource]);

  // If there are no seq numbers (no raw source available), show a single
  // abstract view of the whole message.
  if (seqs.length === 0) {
    const text = JSON.stringify(msg.rawSource ?? msg, jsonReplacer, 2);
    return (
      <div class="message source-view">
        <HighlightedJson text={text} />
      </div>
    );
  }

  return (
    <div class="message source-view">
      {events.map((event, i) => (
        <EventItem
          key={seqs[i] ?? i}
          event={event}
          seq={seqs[i]!}
          tid={tid}
          rawSource={null}
          onEditRaw={onEditRaw}
        />
      ))}
    </div>
  );
}
