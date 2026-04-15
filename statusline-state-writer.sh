#!/usr/bin/env bash
# statusline-state-writer — statusLine command for Claude Code.
#
# Reads JSON state from stdin (provided by the Claude Code harness), persists
# it to a state file so statusline-injector.sh can pick it up on each turn,
# and prints a compact one-line status to stdout (shown in the terminal UI).
#
# stdin schema (fields used downstream):
#   .model.id, .model.display_name
#   .context_window.{used_percentage, remaining_percentage, ...}
#   .rate_limits.five_hour.{used_percentage, resets_at}
#   .rate_limits.seven_day.{used_percentage, resets_at}
#
# Requires: bash, jq, mktemp, mkdir, printf.

set -u

# --- config (override via env) ---
: "${STATUSLINE_STATE_FILE:=$HOME/.claude/statusline-injector/state.json}"

# Force C locale so printf produces dot decimals (not comma under ru_RU).
export LC_ALL=C

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 0
fi

STATE_DIR="$(dirname "$STATUSLINE_STATE_FILE")"
mkdir -p "$STATE_DIR"

# Capture full input to a temp then atomically move into place so the
# UserPromptSubmit hook never reads a half-written file.
TMP="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
cat > "$TMP"
mv "$TMP" "$STATUSLINE_STATE_FILE"

# Compose a short UI status from the captured state.
MODEL=$(jq -r '.model.display_name // .model.id // "?"' "$STATUSLINE_STATE_FILE" 2>/dev/null)
CTX=$(jq -r '.context_window.used_percentage // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null)
RL5=$(jq -r '.rate_limits.five_hour.used_percentage // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null)
RL7=$(jq -r '.rate_limits.seven_day.used_percentage // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null)

OUT="$MODEL"
[ -n "$CTX" ] && OUT="$OUT | ctx $(printf '%.0f' "$CTX")%"
[ -n "$RL5" ] && OUT="$OUT | 5h $(printf '%.0f' "$RL5")%"
[ -n "$RL7" ] && OUT="$OUT | 7d $(printf '%.0f' "$RL7")%"
echo "$OUT"
