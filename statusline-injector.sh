#!/usr/bin/env bash
# statusline-injector — UserPromptSubmit hook for Claude Code.
#
# On every user turn, reads the hook input from stdin (transcript_path, etc),
# parses the live transcript JSONL for tokens/model/context, reads the
# persisted state file (written by statusline-state-writer.sh) for
# subscription rate_limits, and prints a short status block to stdout.
# With exit code 0 the harness injects that stdout into Claude's user-message
# context, so the agent sees its own fresh status before every turn.
#
# Config via env vars (see config.example.env). All fields can be toggled
# individually. Defaults show everything.
#
# Requires: bash, jq, awk, date, printf.

set -u

# --- config (override via env) ---
: "${STATUSLINE_STATE_FILE:=$HOME/.claude/statusline-injector/state.json}"
: "${STATUSLINE_TITLE:=status}"
: "${STATUSLINE_SHOW_TIME:=1}"
: "${STATUSLINE_SHOW_MODEL:=1}"
: "${STATUSLINE_SHOW_SESSION:=1}"
: "${STATUSLINE_SHOW_CONTEXT:=1}"
: "${STATUSLINE_SHOW_SUBSCRIPTION:=1}"
: "${STATUSLINE_WARN_5H:=85}"
: "${STATUSLINE_CRIT_5H:=95}"
: "${STATUSLINE_WATCH_5H:=70}"
: "${STATUSLINE_WARN_7D:=85}"
: "${STATUSLINE_CRIT_7D:=95}"

# Force C locale so awk/printf produce dot decimals (not comma under ru_RU).
export LC_ALL=C

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "[statusline-injector] error: jq is required but not found" >&2
  exit 0  # do not block the turn
fi

# --- read hook input from stdin ---
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat)
fi
TRANSCRIPT=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

# --- defaults ---
MODEL="?"
SESS_IN=0
SESS_OUT=0
CTX_TOKENS=0
CTX_PCT="?"
WINDOW=0
RL_5H=""
RL_7D=""
RL_5H_RESET=""
RL_7D_RESET=""

# --- model id: prefer state file (has full id including [1m] suffix) ---
# Transcript JSONL records only the base id (e.g. "claude-opus-4-6"), without
# the "[1m]" suffix that signals the 1M context window. state.json has the
# precise variant so the window-size derivation below is correct.
if [ -f "$STATUSLINE_STATE_FILE" ]; then
  STATE_MODEL=$(jq -r '.model.id // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null || true)
  [ -n "$STATE_MODEL" ] && MODEL="$STATE_MODEL"
fi

# --- parse transcript for tokens (and model fallback) ---
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Fallback model id from transcript if state.json was missing.
  if [ "$MODEL" = "?" ]; then
    MODEL=$(jq -rs '[.[] | .message.model // empty] | last // "?"' "$TRANSCRIPT" 2>/dev/null || echo "?")
  fi

  # Cumulative session tokens across all assistant entries.
  SESS_IN=$(jq -s '[.[] | .message.usage.input_tokens // 0] | add // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)
  SESS_OUT=$(jq -s '[.[] | .message.usage.output_tokens // 0] | add // 0' "$TRANSCRIPT" 2>/dev/null || echo 0)

  # Last context size = input + cache_read + cache_creation from the most
  # recent assistant.message.usage. cache_read counts toward the context the
  # model actually sees, so it is added.
  LAST_USAGE=$(jq -s 'map(select(.message.usage != null)) | last // empty | .message.usage' "$TRANSCRIPT" 2>/dev/null)
  if [ -n "$LAST_USAGE" ] && [ "$LAST_USAGE" != "null" ]; then
    LI=$(printf '%s' "$LAST_USAGE" | jq -r '.input_tokens // 0')
    LR=$(printf '%s' "$LAST_USAGE" | jq -r '.cache_read_input_tokens // 0')
    LC=$(printf '%s' "$LAST_USAGE" | jq -r '.cache_creation_input_tokens // 0')
    CTX_TOKENS=$((LI + LR + LC))
  fi
fi

# --- pick context window from model id ---
case "$MODEL" in
  *"[1m]"*|*"-1m"*) WINDOW=1000000 ;;
  *)                 WINDOW=200000  ;;
esac
if [ "$CTX_TOKENS" -gt 0 ] && [ "$WINDOW" -gt 0 ]; then
  CTX_PCT=$(awk -v c="$CTX_TOKENS" -v w="$WINDOW" 'BEGIN { printf "%.1f", (c/w)*100 }')
fi

# --- parse subscription limits from state file ---
#
# resets_at is observed as epoch seconds (integer) in current Claude Code
# builds. Format it portably across BSD/GNU date:
#   macOS/BSD: date -r EPOCH '+FMT'
#   GNU:       date -d @EPOCH '+FMT'
# Detect once, reuse.
fmt_epoch() {
  local ts="$1" fmt="$2"
  # Input guard: only accept pure-digit epoch. If Claude Code ever switches
  # to ISO-8601 here, fall through to python as a last resort.
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    if date -r 0 '+%s' >/dev/null 2>&1; then
      date -r "$ts" "+$fmt" 2>/dev/null
    else
      date -d "@$ts" "+$fmt" 2>/dev/null
    fi
  else
    # Non-epoch (e.g. ISO-8601). Try python3 if available.
    command -v python3 >/dev/null 2>&1 && \
      python3 -c "import sys, datetime as d; print(d.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone().strftime(sys.argv[2]))" "$ts" "$fmt" 2>/dev/null
  fi
}

if [ "$STATUSLINE_SHOW_SUBSCRIPTION" = "1" ] && [ -f "$STATUSLINE_STATE_FILE" ]; then
  RL_5H=$(jq -r '.rate_limits.five_hour.used_percentage // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null || true)
  RL_7D=$(jq -r '.rate_limits.seven_day.used_percentage // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null || true)
  RL_5H_TS=$(jq -r '.rate_limits.five_hour.resets_at // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null || true)
  RL_7D_TS=$(jq -r '.rate_limits.seven_day.resets_at // empty' "$STATUSLINE_STATE_FILE" 2>/dev/null || true)
  [ -n "$RL_5H_TS" ] && RL_5H_RESET=$(fmt_epoch "$RL_5H_TS" '%H:%M')
  [ -n "$RL_7D_TS" ] && RL_7D_RESET=$(fmt_epoch "$RL_7D_TS" '%d.%m')
fi

# --- formatting helpers ---
fmt_n() {
  local n="$1"
  if [ "$n" -ge 1000 ]; then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  else
    echo "$n"
  fi
}

# --- escalating warnings on subscription limits ---
WARN=""
if [ -n "$RL_5H" ]; then
  if   awk -v p="$RL_5H" -v t="$STATUSLINE_CRIT_5H"  'BEGIN { exit !(p >= t) }'; then WARN=" 🔴 5h CRITICAL"
  elif awk -v p="$RL_5H" -v t="$STATUSLINE_WARN_5H"  'BEGIN { exit !(p >= t) }'; then WARN=" ⚠️ 5h close"
  elif awk -v p="$RL_5H" -v t="$STATUSLINE_WATCH_5H" 'BEGIN { exit !(p >= t) }'; then WARN=" ⚡ 5h watch"
  fi
fi
if [ -n "$RL_7D" ]; then
  if   awk -v p="$RL_7D" -v t="$STATUSLINE_CRIT_7D" 'BEGIN { exit !(p >= t) }'; then WARN="$WARN 🔴 7d CRITICAL"
  elif awk -v p="$RL_7D" -v t="$STATUSLINE_WARN_7D" 'BEGIN { exit !(p >= t) }'; then WARN="$WARN ⚠️ 7d close"
  fi
fi

NOW=$(date '+%Y-%m-%d %H:%M %z')
SESS_IN_F=$(fmt_n "$SESS_IN")
SESS_OUT_F=$(fmt_n "$SESS_OUT")
WIN_K=$((WINDOW / 1000))

# --- render status block — stdout is injected into Claude's context ---
# Title line always present (anchors the block for attention).
if [ "$STATUSLINE_SHOW_TIME" = "1" ]; then
  printf '[%s @ %s]\n' "$STATUSLINE_TITLE" "$NOW"
else
  printf '[%s]\n' "$STATUSLINE_TITLE"
fi

[ "$STATUSLINE_SHOW_MODEL" = "1" ] && printf -- '- model: %s\n' "$MODEL"

if [ "$STATUSLINE_SHOW_SESSION" = "1" ]; then
  printf -- '- session: ↓%s / ↑%s tokens\n' "$SESS_IN_F" "$SESS_OUT_F"
fi

if [ "$STATUSLINE_SHOW_CONTEXT" = "1" ]; then
  printf -- '- context: %s%% of %sk window\n' "$CTX_PCT" "$WIN_K"
fi

if [ "$STATUSLINE_SHOW_SUBSCRIPTION" = "1" ] && { [ -n "$RL_5H" ] || [ -n "$RL_7D" ]; }; then
  printf -- '- subscription: 5h %s%%%s / 7d %s%%%s%s\n' \
    "${RL_5H:-?}" \
    "${RL_5H_RESET:+ (resets $RL_5H_RESET)}" \
    "${RL_7D:-?}" \
    "${RL_7D_RESET:+ (resets $RL_7D_RESET)}" \
    "$WARN"
fi

exit 0
