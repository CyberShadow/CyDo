#!/usr/bin/env bash
# Generate docs/icons/*.svg from web/src/icons/*.svg for use in the README.
#
# The source icons use fill="currentColor" which doesn't resolve usefully
# inside GitHub's <img> rendering pipeline. This script copies the relevant
# icons and injects a <style> block that sets the color via
# prefers-color-scheme, using a yellow→green gradient matching the CyDo logo.
#
# Usage:
#   docs/tools/gen-readme-icons.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/web/src/icons"
DST="$REPO_ROOT/docs/icons"

COMMENT='<!-- Generated from web/src/icons/ by docs/tools/gen-readme-icons.sh -->'

# Icon names with their light/dark colors (yellow→green gradient from logo).
# Order matches the README task type table.
#              name          light    dark
ICONS=(
  "conversation #c29913 #f1d373"
  "bug          #bbae18 #ede472"
  "reproduce    #a6b31d #dfe971"
  "plan         #8aab22 #c9e56f"
  "spike        #72a427 #b3e16f"
  "triage       #5e9c2c #9fdd6e"
  "implement    #4d9531 #8cd86d"
  "review       #408e35 #7ad36d"
  "verify       #3a873c #6dce70"
)

mkdir -p "$DST"

for entry in "${ICONS[@]}"; do
  read -r icon light dark <<< "$entry"
  src="$SRC/${icon}.svg"
  dst="$DST/${icon}.svg"

  if [[ ! -f "$src" ]]; then
    echo "WARNING: $src not found, skipping" >&2
    continue
  fi

  style="<style>svg{color:${light}}@media(prefers-color-scheme:dark){svg{color:${dark}}}</style>"

  # Read source, collapse to single line, inject style before closing </svg>,
  # and prepend the generated-file comment.
  content=$(tr '\n' ' ' < "$src" | sed 's/  */ /g')
  content="${content//<\/svg>/${style}<\/svg>}"

  printf '%s\n%s\n' "$COMMENT" "$content" > "$dst"
  echo "  $icon.svg"
done

echo "Done — ${#ICONS[@]} icons written to docs/icons/"
