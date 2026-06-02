#!/usr/bin/env bash
# statusline-injector — statusLine wrapper (Claude Code only).
#
# Installed as the project-scope statusLine.command by the SessionStart hook
# (statusline-session-start.sh). The harness pipes a JSON state blob to this
# script on every render — that blob is the ONLY channel carrying the
# subscription rate_limits (5h/7d) and the live context_window. We:
#
#   1. persist the full blob to a per-session state file (atomic write) so the
#      UserPromptSubmit injector can read the rate_limits / context it cannot
#      otherwise see;
#   2. pass the SAME stdin to the user's original statusLine command (received
#      as $1) and echo its stdout verbatim — so the user's TUI line is
#      preserved untouched. The wrapper is agnostic to the original's language;
#   3. if there is no original, render our own minimal line so a previously
#      bare statusLine still shows something useful.
#
# This script lives at a STABLE path (~/.claude/statusline-injector/wrapper.sh
# by default), materialized forward-only by the SessionStart hook, so it keeps
# working even after a plugin update or uninstall — the user's statusLine never
# breaks.
#
# Invariant: always exit 0; never block a render.

set -u
export LC_ALL=C

: "${STATUSLINE_STATE_DIR:=$HOME/.claude/statusline-injector}"

# Capture the harness blob from stdin.
IN=""
if [ ! -t 0 ]; then IN=$(cat); fi

# Key the state file by session_id so concurrent sessions never clobber each
# other's model/context (rate_limits are account-global, but context is not).
SID=""
if [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  SID=$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null || true)
fi

mkdir -p "$STATUSLINE_STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATUSLINE_STATE_DIR/state${SID:+-$SID}.json"

# Atomic write: temp + mv, so the injector never reads a half-written file.
if [ -n "$IN" ]; then
  TMP=$(mktemp "$STATUSLINE_STATE_DIR/.state.XXXXXX" 2>/dev/null || true)
  if [ -n "$TMP" ]; then
    printf '%s' "$IN" > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE_FILE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
  fi
fi

# Pass through to the user's original statusLine command, if any.
ORIG="${1:-}"
if [ -n "$ORIG" ]; then
  # eval re-parses the stored command string (it is the user's own command,
  # e.g. `bash -c '…'`, a script path, or a jq one-liner). Feed it the same
  # stdin and surface its stdout. Never let its failure break the render.
  printf '%s' "$IN" | eval "$ORIG" 2>/dev/null || true
  exit 0
fi

# No original statusLine — render our own minimal line for the TUI, straight
# from the rich blob we just captured.
if [ -z "$IN" ] || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# The harness runs the statusLine command WITHOUT plugin env, so
# CLAUDE_PLUGIN_ROOT is usually unset here. The SessionStart hook materializes
# statusline-lib.sh beside this wrapper at the stable path — prefer that
# sibling, then fall back to the plugin root if we happen to run in-tree.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/statusline-lib.sh"
[ -f "$LIB" ] || LIB="${CLAUDE_PLUGIN_ROOT:-}/scripts/statusline-lib.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=/dev/null
. "$LIB"

SL_CTX_USED=$(printf '%s' "$IN" | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null || true)
SL_CTX_WIN=$(printf '%s' "$IN" | jq -r '.context_window.context_window_size // empty' 2>/dev/null || true)
SL_RL5=$(printf '%s' "$IN" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
SL_RL5_RESET=$(printf '%s' "$IN" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null || true)
SL_RL7=$(printf '%s' "$IN" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)
SL_RL7_RESET=$(printf '%s' "$IN" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null || true)
export SL_CTX_USED SL_CTX_WIN SL_RL5 SL_RL5_RESET SL_RL7 SL_RL7_RESET
sl_render
printf '\n'
exit 0
