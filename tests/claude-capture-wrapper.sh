#!/bin/sh
exec bash -c '
  set -euo pipefail
  : "${CYDO_REAL_CLAUDE_BIN:?CYDO_REAL_CLAUDE_BIN is required}"
  : "${CYDO_CAPTURE_DIR:?CYDO_CAPTURE_DIR is required}"
  mkdir -p "$CYDO_CAPTURE_DIR"
  exec < <(tee -a "$CYDO_CAPTURE_DIR/stdin.ndjson") \
       > >(tee -a "$CYDO_CAPTURE_DIR/stdout.ndjson")
  exec "$CYDO_REAL_CLAUDE_BIN" "$@"
' claude-capture-wrapper "$@"
