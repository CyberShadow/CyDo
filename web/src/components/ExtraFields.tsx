import { h } from "preact";

interface Props {
  fields: Record<string, unknown> | undefined;
}

export function ExtraFields({ fields }: Props) {
  if (!fields || Object.keys(fields).length === 0) return null;

  return (
    <details class="extra-fields">
      <summary>Additional fields ({Object.keys(fields).length})</summary>
      <div class="extra-fields-content">
        {Object.entries(fields).map(([key, value]) => {
          const str = typeof value === "string" ? value : JSON.stringify(value, null, 2);
          const isMultiline = str.includes("\n");
          return (
            <div key={key} class="extra-field">
              <span class="extra-field-key">{key}:</span>
              {isMultiline
                ? <pre class="extra-field-value">{str}</pre>
                : <span class="extra-field-value"> {str}</span>
              }
            </div>
          );
        })}
      </div>
    </details>
  );
}
