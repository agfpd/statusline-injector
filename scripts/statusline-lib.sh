#!/usr/bin/env bash
# statusline-injector — shared rendering library.
#
# Sourced by the hook scripts. Pure functions that turn a small set of
# normalized inputs into the single minimal status line that gets injected
# into the agent's context. Runtime-agnostic: the caller fills the SL_*
# globals from whichever source applies (Claude state/transcript or Codex
# rollout), then calls sl_render.
#
# Output line: [st 14:30+03]. Time is ALWAYS shown. Context and the 5h/7d
# limits are appended — as plain neutral facts, bare numbers — only when each
# exceeds the show threshold (SL_SHOW_PCT, default 50% of its own cap). So a
# healthy turn is just [st 14:30+03]; a loaded one is
# [st 14:30+03 · ctx 150k/200k · 5h 62%]. No reset countdown, no warning marker:
# the line is data the agent can act on near a boundary, never an alarm.
#
# Invariant: nothing here may exit non-zero or block a turn. LC_ALL=C must be
# set by the caller before sourcing (keeps awk/printf on dot decimals).

# --- plugin root resolution (Claude: CLAUDE_PLUGIN_ROOT, Codex: PLUGIN_ROOT,
#     fallback: the dir of the calling script). §2 of the team plugin standard. ---
sl_resolve_root() {
  local src
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  elif [ -n "${PLUGIN_ROOT:-}" ]; then
    printf '%s' "$PLUGIN_ROOT"
  else
    # ${BASH_SOURCE[1]} is the script that sourced this lib.
    src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    # scripts/ lives directly under the plugin root.
    ( cd "$(dirname "$src")/.." 2>/dev/null && pwd )
  fi
}

# --- time: local HH:MM + compact offset, fallback UTC. TZ from the system,
#     never hardcoded. ---
sl_now() {
  local hm z sign hh mm
  hm=$(date '+%H:%M' 2>/dev/null)
  z=$(date '+%z' 2>/dev/null)
  if [ -z "$hm" ]; then
    hm=$(date -u '+%H:%M' 2>/dev/null)
    z="+0000"
  fi
  # z looks like +0300 / -0530 / +0000. Compact: drop ":00" minutes.
  if [ -n "$z" ] && [ "${#z}" -ge 5 ]; then
    sign="${z:0:1}"; hh="${z:1:2}"; mm="${z:3:2}"
    if [ "$mm" = "00" ]; then
      printf '%s%s%s' "$hm" "$sign" "$hh"
    else
      printf '%s%s%s%s' "$hm" "$sign" "$hh" "$mm"
    fi
  else
    printf '%s' "$hm"
  fi
}

# --- portable epoch → "HH:MM" (BSD date -r, GNU date -d @, python3 fallback).
#     Retained utility: the neutral line no longer prints reset times, but the
#     resets_at data is still captured upstream, so this stays wired-in-waiting
#     rather than deleted. ---
sl_fmt_reset() {
  local ts="$1"
  case "$ts" in
    ''|*[!0-9]*) # not pure epoch — try python3 (handles ISO-8601 if it ever appears)
      command -v python3 >/dev/null 2>&1 && \
        python3 -c "import sys,datetime as d; print(d.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone().strftime('%H:%M'))" "$ts" 2>/dev/null
      return ;;
  esac
  if date -r 0 '+%s' >/dev/null 2>&1; then
    date -r "$ts" '+%H:%M' 2>/dev/null
  else
    date -d "@$ts" '+%H:%M' 2>/dev/null
  fi
}

# --- token count → compact "70k" (rounded), raw if < 1000. ---
sl_fmt_tokens() {
  local n="$1"
  case "$n" in ''|*[!0-9]*) printf ''; return ;; esac
  if [ "$n" -ge 1000 ]; then
    awk -v n="$n" 'BEGIN { printf "%dk", int((n + 500) / 1000) }'
  else
    printf '%s' "$n"
  fi
}

# --- window size → "200k" / "1m". ---
sl_fmt_window() {
  local w="$1"
  case "$w" in ''|*[!0-9]*) printf ''; return ;; esac
  if [ "$w" -ge 1000000 ]; then
    awk -v w="$w" 'BEGIN { m = w / 1000000; if (m == int(m)) printf "%dm", m; else printf "%.1fm", m }'
  else
    awk -v w="$w" 'BEGIN { printf "%dk", int((w + 500) / 1000) }'
  fi
}

# --- one rate-limit segment. Injected ONLY when usage exceeds the show
#     threshold (SL_SHOW_PCT, default 50) — as a plain neutral fact " · 5h 62%":
#     a bare percentage, no reset time and no alarm marker. Empty below the
#     threshold or when pct is absent. ---
sl_render_limit() {
  local label="$1" pct="$2" p
  [ -n "$pct" ] || return 0
  awk -v p="$pct" -v t="${SL_SHOW_PCT:-50}" 'BEGIN { exit !(p + 0 > t + 0) }' || return 0
  p=$(printf '%.0f' "$pct" 2>/dev/null) || p="$pct"
  printf ' · %s %s%%' "$label" "$p"
}

# --- assemble the bracketed line from the SL_* globals. Time is always present;
#     context and limits are threshold-gated (SL_SHOW_PCT, default 50) so a
#     healthy turn collapses to just [st HH:MM±TZ]. ---
# Globals consumed (any may be empty): SL_CTX_USED SL_CTX_WIN SL_RL5 SL_RL7 ;
#   show threshold SL_SHOW_PCT (default 50, percent of each metric's cap).
sl_render() {
  local parts ctx
  parts="st $(sl_now)"
  # Context: injected only when occupancy exceeds SL_SHOW_PCT of the window,
  # as a plain "used/window" fact. Below the threshold it is not surfaced.
  case "${SL_CTX_USED:-}" in
    ''|*[!0-9]*) : ;;
    *) case "${SL_CTX_WIN:-}" in
         ''|*[!0-9]*) : ;;
         *) if [ "$SL_CTX_WIN" -gt 0 ] && \
              awk -v u="$SL_CTX_USED" -v w="$SL_CTX_WIN" -v t="${SL_SHOW_PCT:-50}" \
                  'BEGIN { exit !(u * 100 > w * t) }'; then
              ctx="$(sl_fmt_tokens "$SL_CTX_USED")/$(sl_fmt_window "$SL_CTX_WIN")"
              [ "$ctx" != "/" ] && parts="$parts · ctx $ctx"
            fi ;;
       esac ;;
  esac
  parts="$parts$(sl_render_limit 5h "${SL_RL5:-}")"
  parts="$parts$(sl_render_limit 7d "${SL_RL7:-}")"
  printf '[%s]' "$parts"
}

# --- emit as a UserPromptSubmit hook result. JSON additionalContext form works
#     for both Claude Code and Codex; plain stdout is the jq-absent fallback. ---
sl_emit_userprompt() {
  local line="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ctx "$line" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
  else
    printf '%s\n' "$line"
  fi
}
