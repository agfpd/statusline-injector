#!/usr/bin/env bash
# statusline-injector — UserPromptSubmit hook (Claude Code + Codex CLI).
#
# On every user turn, renders ONE minimal status line and injects it into the
# agent's context (via hookSpecificOutput.additionalContext). Time is always
# shown; context and the 5h/7d limits are appended only when each exceeds the
# show threshold (SL_SHOW_PCT, default 50%), as a plain neutral fact:
#
#   [st 14:30+03]                            (a healthy turn — just the clock)
#   [st 14:30+03 · ctx 150k/200k · 5h 62%]   (context + 5h limit past 50%)
#
# Sources, per runtime:
#   Claude — rate_limits + context_window from the per-session state file the
#            statusLine wrapper persisted; context falls back to the transcript
#            (last usage input+cache) on older Claude builds without
#            context_window in the statusLine blob.
#   Codex  — rate_limits + context from the session rollout
#            (~/.codex/sessions/**/rollout-*.jsonl, last `token_count` event:
#            rate_limits.primary/secondary + info.last_token_usage +
#            model_context_window). No statusLine wrapper involved.
#
# Invariant: always exit 0; a status line is a nice-to-have, never a blocker.

set -u
export LC_ALL=C

ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}}"
: "${STATUSLINE_STATE_DIR:=$HOME/.claude/statusline-injector}"

LIB="$ROOT/scripts/statusline-lib.sh"
[ -f "$LIB" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$LIB"

# --- read hook input ---
HOOK_INPUT=""
if [ ! -t 0 ]; then HOOK_INPUT=$(cat 2>/dev/null || true); fi
SID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TPATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$CWD" ] || CWD="$PWD"

# --- normalized output globals ---
SL_CTX_USED=""; SL_CTX_WIN=""
SL_RL5=""; SL_RL5_RESET=""; SL_RL7=""; SL_RL7_RESET=""

# --- runtime detection (multi-signal, best-effort) ---
# The most reliable signal is the transcript filename: Codex passes the session
# rollout (rollout-*.jsonl), Claude passes a <uuid>.jsonl under .claude/projects.
# Filename beats path/env because the Codex rollout may live outside ~/.codex
# (custom CODEX_HOME) and Codex may also export CLAUDE_PLUGIN_ROOT.
RUNTIME=""
case "$(basename "$TPATH" 2>/dev/null)" in
  rollout-*.jsonl) RUNTIME="codex" ;;
esac
if [ -z "$RUNTIME" ]; then
  case "$TPATH" in
    */.codex/*)  RUNTIME="codex" ;;
    */.claude/*) RUNTIME="claude" ;;
  esac
fi
if [ -z "$RUNTIME" ]; then
  if [ -n "${PLUGIN_ROOT:-}" ] && [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    RUNTIME="codex"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    RUNTIME="claude"
  fi
fi
if [ -z "$RUNTIME" ]; then
  if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then RUNTIME="claude"; else RUNTIME="codex"; fi
fi

# --- Claude: state file (+ transcript fallback for context) ---
gather_claude() {
  local state
  state="$STATUSLINE_STATE_DIR/state${SID:+-$SID}.json"
  [ -f "$state" ] || state="$STATUSLINE_STATE_DIR/state.json"
  if [ -f "$state" ]; then
    SL_RL5=$(jq -r '.rate_limits.five_hour.used_percentage // empty'  "$state" 2>/dev/null || true)
    SL_RL5_RESET=$(jq -r '.rate_limits.five_hour.resets_at // empty'  "$state" 2>/dev/null || true)
    SL_RL7=$(jq -r '.rate_limits.seven_day.used_percentage // empty'  "$state" 2>/dev/null || true)
    SL_RL7_RESET=$(jq -r '.rate_limits.seven_day.resets_at // empty'  "$state" 2>/dev/null || true)
    SL_CTX_USED=$(jq -r '.context_window.total_input_tokens // empty' "$state" 2>/dev/null || true)
    SL_CTX_WIN=$(jq -r '.context_window.context_window_size // empty' "$state" 2>/dev/null || true)
  fi
  # Context fallback from the transcript (older Claude: no context_window blob).
  if [ -z "$SL_CTX_USED" ] && [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
    # Stream JSONL, tolerating a partial final write. Validate before adding:
    # shell arithmetic on malformed usage can terminate even a fail-open hook.
    SL_CTX_USED=$(grep -F '"usage"' "$TPATH" 2>/dev/null | jq -Rnr '
      reduce inputs as $line (null;
        (($line | fromjson? | .message.usage?) // null) as $u
        | ([$u.input_tokens // 0, $u.cache_read_input_tokens // 0,
            $u.cache_creation_input_tokens // 0]) as $n
        | if ($u | type) == "object" and
             ($n | all(.[]; type == "number" and . >= 0 and floor == .))
          then ($n | add) else . end)
      | . // empty
    ' 2>/dev/null || true)
  fi
  # Window fallback: default 200k when the window size is unknown (e.g. state not
  # yet written this session). Modern Claude (>= v2.1.132) delivers
  # context_window_size directly in the statusLine blob — 200000 or 1000000 — so
  # the real size (incl. 1m models) comes from $state above, not from here.
  if [ -z "$SL_CTX_WIN" ]; then
    SL_CTX_WIN=200000
  fi
}

# --- Codex: locate the session rollout by cwd, read last token_count ---
codex_find_rollout() {
  local want root f meta metacwd
  want=$(printf '%s' "$CWD" | sed 's:/*$::')
  root="${CODEX_HOME:-$HOME/.codex}/sessions"
  [ -d "$root" ] || return 1
  # Newest-first; the current session's rollout was just appended (the user
  # prompt), so it sorts near the top. Cap the scan for cheapness.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    meta=$(head -n 1 "$f" 2>/dev/null || true)
    metacwd=$(printf '%s' "$meta" | jq -r '.payload.cwd // .cwd // empty' 2>/dev/null || true)
    metacwd=$(printf '%s' "$metacwd" | sed 's:/*$::')
    if [ -n "$metacwd" ] && [ "$metacwd" = "$want" ]; then
      printf '%s' "$f"; return 0
    fi
  done <<EOF
$(find "$root" -type f -name 'rollout-*.jsonl' -exec ls -t {} + 2>/dev/null | head -60)
EOF
  return 1
}

gather_codex() {
  local ro snapshot pu pw pr su sw sr
  # Codex passes transcript_path on the hook — for codex it is the session
  # rollout itself. Prefer it (exact), fall back to locating by cwd.
  if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
    ro="$TPATH"
  else
    ro=$(codex_find_rollout) || ro=""
  fi
  [ -n "$ro" ] || return 0
  # Keep context and limits independently: a rate-only event has info:null;
  # a context-only event has rate_limits:null. Neither erases the last sample.
  # Raw-input streaming avoids slurping a long session and ignores an incomplete
  # final line while the harness is appending. Other event types are not usage.
  snapshot=$(grep -F '"token_count"' "$ro" 2>/dev/null | jq -Rnc '
    reduce inputs as $line ({};
      (($line | fromjson? | select(.type == "event_msg")
        | .payload | select(.type == "token_count")) // null) as $p
      | if ($p.info | type) == "object" then .info = $p.info else . end
      | if ($p.rate_limits | type) == "object"
        then .rate_limits = $p.rate_limits else . end)
  ' 2>/dev/null || true)
  SL_CTX_USED=$(printf '%s' "$snapshot" | jq -r '.info.last_token_usage.input_tokens // empty' 2>/dev/null || true)
  SL_CTX_WIN=$(printf '%s' "$snapshot" | jq -r '.info.model_context_window // empty' 2>/dev/null || true)
  # Assign primary/secondary to 5h/7d by window_minutes (300 vs 10080) rather
  # than position, to be robust if the order ever changes.
  pu=$(printf '%s' "$snapshot" | jq -r '.rate_limits.primary.used_percent   // empty' 2>/dev/null || true)
  pw=$(printf '%s' "$snapshot" | jq -r '.rate_limits.primary.window_minutes  // empty' 2>/dev/null || true)
  pr=$(printf '%s' "$snapshot" | jq -r '.rate_limits.primary.resets_at       // empty' 2>/dev/null || true)
  su=$(printf '%s' "$snapshot" | jq -r '.rate_limits.secondary.used_percent  // empty' 2>/dev/null || true)
  sw=$(printf '%s' "$snapshot" | jq -r '.rate_limits.secondary.window_minutes // empty' 2>/dev/null || true)
  sr=$(printf '%s' "$snapshot" | jq -r '.rate_limits.secondary.resets_at      // empty' 2>/dev/null || true)
  codex_assign_limit "$pw" "$pu" "$pr"
  codex_assign_limit "$sw" "$su" "$sr"
}
codex_assign_limit() {
  local wm="$1" used="$2" reset="$3"
  [ -n "$used" ] || return 0
  # Split by threshold, not exact 300/10080: survives a change of window length.
  case "$wm" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$wm" -le 600 ]; then
    SL_RL5="$used"; SL_RL5_RESET="$reset"
  else
    SL_RL7="$used"; SL_RL7_RESET="$reset"
  fi
}

if [ "$RUNTIME" = "codex" ]; then
  gather_codex
else
  gather_claude
fi

# Optional debug trace for live verification.
if [ -n "${STATUSLINE_DEBUG:-}" ]; then
  mkdir -p "$STATUSLINE_STATE_DIR" 2>/dev/null || true
  printf '%s rt=%s sid=%s ctx=%s/%s 5h=%s 7d=%s tpath=%s cwd=%s\n' \
    "$(date '+%H:%M:%S')" "$RUNTIME" "$SID" "$SL_CTX_USED" "$SL_CTX_WIN" \
    "$SL_RL5" "$SL_RL7" "$TPATH" "$CWD" >> "$STATUSLINE_STATE_DIR/inject-debug.log" 2>/dev/null || true
fi

export SL_CTX_USED SL_CTX_WIN SL_RL5 SL_RL5_RESET SL_RL7 SL_RL7_RESET
sl_emit_userprompt "$(sl_render)"
exit 0
