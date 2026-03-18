#!/usr/bin/env bash
set -o pipefail
"$CYDO_REAL_CLAUDE_BIN" "$@" | node "$(dirname "$0")/extra-fields-inject.mjs"
