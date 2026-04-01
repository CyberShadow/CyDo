#!/bin/sh

prompt=""
next_is_prompt=0
next_is_output=0
is_text_output=0

for arg in "$@"; do
  if [ "$next_is_prompt" -eq 1 ]; then
    prompt=$arg
    next_is_prompt=0
    continue
  fi

  if [ "$next_is_output" -eq 1 ]; then
    if [ "$arg" = "text" ]; then
      is_text_output=1
    fi
    next_is_output=0
    continue
  fi

  case "$arg" in
    -p)
      next_is_prompt=1
      ;;
    --output-format)
      next_is_output=1
      ;;
  esac
done

if [ "$is_text_output" -eq 1 ]; then
  case "$prompt" in
    *"Generate a concise title"*)
      if [ -n "$CYDO_TEST_TITLE" ]; then
        printf '%s\n' "$CYDO_TEST_TITLE"
        exit 0
      fi
      echo "CYDO_TEST_TITLE missing from one-shot environment" >&2
      exit 1
      ;;
  esac
fi

exec "$CYDO_REAL_CLAUDE_BIN" "$@"
