#!/usr/bin/env bash
# Test multi-turn conversation with Claude Code stream-json protocol.
#
# Usage:
#   ./test/test-stream-json.sh
#   ./test/test-stream-json.sh 2>/dev/null | ~/libexec/format-claude-session
#
# Prerequisites: `claude` CLI in PATH.

set -euo pipefail

# --- Config ---
MODEL="${MODEL:-haiku}"
MAX_TURNS="${MAX_TURNS:-3}"
TURN_DELAY="${TURN_DELAY:-5}"  # seconds to wait between turns

log() { echo "$*" >&2; }

# --- Main ---

log "=== Claude Code stream-json multi-turn test ==="
log "Model: $MODEL | Max turns: $MAX_TURNS"
log ""

OUTPUT=$(mktemp)
trap 'rm -f "$OUTPUT"' EXIT

# Feed multiple messages with delays between them.
# Use env -u CLAUDECODE to allow running from within a Claude Code session.
{
    # Turn 1: establish a fact
    log "--- Turn 1: sending ---"
    jq -nc '{
        type: "user",
        message: { role: "user", content: "I am working on a project called Mango. Please acknowledge." },
        session_id: "default",
        parent_tool_use_id: null
    }'
    sleep "$TURN_DELAY"

    # Turn 2: test recall
    log "--- Turn 2: sending ---"
    jq -nc '{
        type: "user",
        message: { role: "user", content: "What is the name of my project?" },
        session_id: "default",
        parent_tool_use_id: null
    }'
    sleep "$TURN_DELAY"

    # Turn 3: test session awareness
    log "--- Turn 3: sending ---"
    jq -nc '{
        type: "user",
        message: { role: "user", content: "How many user messages have I sent so far? Just the number." },
        session_id: "default",
        parent_tool_use_id: null
    }'
    sleep "$TURN_DELAY"
} | env -u CLAUDECODE claude -p \
    --input-format stream-json \
    --output-format stream-json \
    --verbose \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --permission-mode dontAsk \
    --no-session-persistence \
    | tee "$OUTPUT"

log ""
log "=== Results ==="

# Parse results
TURN=0
while IFS= read -r line; do
    TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue

    if [[ "$TYPE" == "result" ]]; then
        TURN=$((TURN + 1))
        RESULT=$(echo "$line" | jq -r '.result // ""')
        log "Turn $TURN result: $RESULT"
    fi
done < "$OUTPUT"

log ""

# Validate turn 2 contains "Mango"
TURN2_RESULT=$(jq -s '[.[] | select(.type == "result")] | .[1].result' "$OUTPUT")
if echo "$TURN2_RESULT" | grep -qi "mango"; then
    log "PASS: Claude remembered the project name across turns."
else
    log "FAIL: Expected 'Mango' in turn 2 result, got: $TURN2_RESULT"
    exit 1
fi

log "=== Test complete ==="
