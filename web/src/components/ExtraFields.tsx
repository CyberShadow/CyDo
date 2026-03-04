import { h } from "preact";
import type { ExtraField } from "../extractExtras";

interface Props {
  fields: ExtraField[] | undefined;
}

export function ExtraFields({ fields }: Props) {
  if (!fields || fields.length === 0) return null;

  // Group by path
  const groups = new Map<string, ExtraField[]>();
  for (const field of fields) {
    const key = field.path || "(root)";
    let group = groups.get(key);
    if (!group) {
      group = [];
      groups.set(key, group);
    }
    group.push(field);
  }

  return (
    <details class="extra-fields">
      <summary>Additional fields ({fields.length})</summary>
      <div class="extra-fields-content">
        {Array.from(groups.entries()).map(([path, groupFields]) => (
          <div key={path} class="extra-fields-group">
            {groups.size > 1 && <div class="extra-fields-path">{path}</div>}
            {groupFields.map((field) => {
              const str =
                typeof field.value === "string"
                  ? field.value
                  : JSON.stringify(field.value, null, 2);
              const isMultiline = str.includes("\n");
              return (
                <div key={`${path}.${field.key}`} class="extra-field">
                  <span class="extra-field-key">{field.key}:</span>
                  {isMultiline ? (
                    <pre class="extra-field-value">{str}</pre>
                  ) : (
                    <span class="extra-field-value"> {str}</span>
                  )}
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </details>
  );
}
