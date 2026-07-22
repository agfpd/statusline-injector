#!/usr/bin/env bash
# statusline-injector — SessionStart hook.
#
# Claude Code only. Idempotently wraps the project-scope statusLine.command so
# the harness blob (rate_limits + context_window) is captured to a state file
# while the user's original statusLine keeps rendering untouched. On Codex this
# is a clean no-op (Codex has no statusLine channel; its limits/context come
# from the rollout, read directly by the injector).
#
# Correctness of the wrap (the whole point of wrapping, not replacing):
#   1. No runaway self-wrap. The project-scope statusLine is ALWAYS rewritten
#      whole from a freshly-built wrapper entry; we never wrap the current
#      string. The inner command comes from the stash or user-scope, never from
#      our own project entry — so re-running cannot nest.
#   2. True original. When our wrapper is already installed and the original was
#      user-scope, the inner is re-read LIVE from user-scope each session, so it
#      tracks the user changing their own statusLine.
#   3. Original in project-scope. If the user's statusLine lives in project
#      scope, it is stashed (_statuslineInjectorOriginal) and restored on
#      uninstall — not silently dropped. For user/none origins, uninstall just
#      deletes our project entry and the harness falls back to user-scope.
#
# Invariant: always exit 0; never block session start. No stdout (side-effect
# only), so Codex's JSON-parsed SessionStart output stays empty.

set -u
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0

# Drain stdin (session_id, cwd, transcript_path, …).
HOOK_INPUT=""
if [ ! -t 0 ]; then HOOK_INPUT=$(cat 2>/dev/null || true); fi

# --- Codex bail. Codex has no statusLine channel, so the wrap is meaningless
#     there. Detect Codex by its SessionStart transcript_path (the session
#     rollout, rollout-*.jsonl) and no-op — robust even if a future Codex
#     exports CLAUDE_* vars. ---
SS_TPATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
case "$(basename "$SS_TPATH" 2>/dev/null)" in
  rollout-*.jsonl) exit 0 ;;
esac

# --- Claude-only gate. Without a Claude project/plugin root there is nothing to
#     wrap (and no Codex marker above means an unknown runtime — bail). ---
if [ -z "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
: "${STATUSLINE_STATE_DIR:=$HOME/.claude/statusline-injector}"
WRAPPER="$STATUSLINE_STATE_DIR/wrapper.sh"

mkdir -p "$STATUSLINE_STATE_DIR" 2>/dev/null || true

# --- Retention. The wrapper writes one state-<session_id>.json per session and
#     nothing ever removed them, so the directory grew unbounded (202 files on
#     the fleet host after ~2 weeks). Prune once per session start, by AGE, not
#     count: a live session's state file is re-written on every statusLine
#     render, so its mtime stays fresh — only files of sessions that have been
#     silent for longer than the TTL are removed. A dormant session that wakes
#     after the TTL simply re-creates its file on the next render (worst case:
#     one turn without 5h/7d before the wrapper runs again).
#     Also sweeps abandoned mktemp fragments from interrupted atomic writes.
#     Never fatal: retention is housekeeping, it must not affect session start.
: "${STATUSLINE_STATE_TTL_DAYS:=7}"
if [ "$STATUSLINE_STATE_TTL_DAYS" -gt 0 ] 2>/dev/null; then
  find "$STATUSLINE_STATE_DIR" -maxdepth 1 -type f -name 'state-*.json' \
    -mtime +"$STATUSLINE_STATE_TTL_DAYS" -delete 2>/dev/null || true
fi
find "$STATUSLINE_STATE_DIR" -maxdepth 1 -type f -name '.state.*' \
  -mtime +1 -delete 2>/dev/null || true

# --- §5/§6: materialize wrapper.sh + statusline-lib.sh to the stable path,
#     forward-only — from the NEWEST installed semver snapshot, so a fleet node
#     pinned to an older version cannot overwrite the shared artifact with old
#     code. Falls back to the running plugin root when no cache snapshot exists
#     (e.g. in-tree dev). ---
materialize() {
  local name="$1" dest="$2" src newest top v d
  src="$ROOT/scripts/$name"
  local base="$HOME/.claude/plugins/cache/agfpd/statusline-injector"
  if [ -d "$base" ]; then
    newest=""
    for d in "$base"/*/; do
      d="${d%/}"; v="$(basename "$d")"
      # bash-3.2-safe semver filter: only X.Y.Z dirs (sha-named snapshots sort
      # above numbers under sort -V, so they must be excluded first).
      if [[ "$v" == [0-9]*.[0-9]*.[0-9]* ]] && [ -f "$d/scripts/$name" ]; then
        if [ -z "$newest" ]; then
          newest="$v"
        else
          top=$(printf '%s\n%s\n' "$newest" "$v" | sort -V | tail -1)
          newest="$top"
        fi
      fi
    done
    if [ -n "$newest" ] && [ -f "$base/$newest/scripts/$name" ]; then
      src="$base/$newest/scripts/$name"
    fi
  fi
  if [ -f "$src" ]; then
    cp -f "$src" "$dest" 2>/dev/null || true
  fi
}
materialize "statusline-wrapper.sh" "$WRAPPER"
materialize "statusline-lib.sh" "$STATUSLINE_STATE_DIR/statusline-lib.sh"
chmod +x "$WRAPPER" 2>/dev/null || true

# --- target settings files ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ] && [ -n "$HOOK_INPUT" ]; then
  PROJECT_DIR=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$PROJECT_DIR" ] || exit 0
P="$PROJECT_DIR/.claude/settings.json"
U="$HOME/.claude/settings.json"

mkdir -p "$PROJECT_DIR/.claude" 2>/dev/null || true
[ -f "$P" ] || echo '{}' > "$P" 2>/dev/null || true
[ -f "$P" ] || exit 0

# user-scope statusLine object (or null) — the live "true original" source.
USER_ST="null"
if [ -f "$U" ]; then
  USER_ST=$(jq -c '.statusLine // null' "$U" 2>/dev/null || echo "null")
  [ -n "$USER_ST" ] || USER_ST="null"
fi

# --- idempotent wrap (the 3-point algorithm above) ---
# Self-wrap detection is CONTENT-based, not marker-only: the marker keys
# (_statuslineInjector*) can be stripped by external settings rewrites (the
# harness itself rewrites project settings.json for enabledPlugins etc. and
# normalizes statusLine to its schema). A wrapped command that lost its marker
# must still be recognized as ours and unwrapped to the true original —
# otherwise every re-run nests one more level and the stash is poisoned with a
# wrap (the 2026-06 fleet incident: up to 5 nested levels). sli_unwrap reverses
# the exact construction below (wrapper path + " " + @sh(inner)), level by
# level; sli_orig applies it to whole statusLine objects, following stash
# chains. Keep these defs in sync with statusline-uninstall.sh.
SLI_JQ_DEFS=""
read -r -d '' SLI_JQ_DEFS <<'JQDEFS' || true
  def sli_strip: sub("\\s*#sli:[0-9]+$"; "");
  def sli_unq:
    if (length >= 2 and startswith("'") and endswith("'"))
    then (.[1:-1] | gsub("'\\\\''"; "'"))
    else . end;
  def sli_ours:
    . == $w or startswith($w + " ")
    or test("^[^ ]*statusline-injector/wrapper\\.sh( |$)")
    or test("^[^ ]*/statusline-wrapper\\.sh( |$)");
  def sli_unwrap:
    sli_strip
    | until((sli_ours | not);
        if contains(" ") then (sub("^[^ ]+ +"; "") | sli_unq | sli_strip)
        else "" end);
  def sli_clean:
    del(._statuslineInjectorWrapped, ._statuslineInjectorOriginal,
        ._statuslineInjectorOriginalSource);
  def sli_orig:
    if . == null then null
    elif (._statuslineInjectorWrapped == true
          and ._statuslineInjectorOriginal != null) then
      (._statuslineInjectorOriginal | sli_orig)
    else
      (((.command // "") | sli_unwrap) as $c
       | if $c == "" then null else (sli_clean | .command = $c) end)
    end;
JQDEFS

TMP=$(mktemp "$PROJECT_DIR/.claude/.settings.XXXXXX" 2>/dev/null || true)
[ -n "$TMP" ] || exit 0

jq \
  --arg w "$WRAPPER" \
  --argjson u "$USER_ST" \
  "$SLI_JQ_DEFS"'
  .statusLine as $cur
  | ($u | sli_orig) as $uo
  | (
      ( if ($cur != null and $cur._statuslineInjectorWrapped == true) then
          ( if ($cur._statuslineInjectorOriginalSource == "project")
            then ($cur._statuslineInjectorOriginal | sli_orig)
            else null end )
        else
          ($cur | sli_orig)
        end ) as $po
      | if $po != null then { obj: $po, src: "project" }
        elif $uo != null then { obj: $uo, src: "user" }
        else { obj: null, src: "none" }
        end
    ) as $o
  | .statusLine = {
      type: "command",
      command: ($w + (if (($o.obj.command) // "") != "" then " " + ($o.obj.command | @sh) else "" end)),
      _statuslineInjectorWrapped: true,
      _statuslineInjectorOriginalSource: $o.src,
      _statuslineInjectorOriginal: (if $o.src == "project" then $o.obj else null end)
    }
  ' "$P" > "$TMP" 2>/dev/null \
  && { if cmp -s "$TMP" "$P" 2>/dev/null; then rm -f "$TMP" 2>/dev/null
       else mv -f "$TMP" "$P" 2>/dev/null; fi; } \
  || rm -f "$TMP" 2>/dev/null

# --- Activator: dodge the statusLine init-race. -----------------------------
# Claude Code resolves statusLine.command at session start; the wrap written
# just above (during SessionStart) can land before Claude's settings watcher is
# ready, so the current session keeps the PRE-wrap statusLine and the wrapper
# never runs (no state file → injector shows time+ctx but no 5h/7d). Claude DOES
# hot-reload statusLine on a mid-session settings change (verified live), so a
# detached task — running after the watcher is up — re-touches settings to force
# that reload, activating the wrapper THIS session. Idempotent, self-stopping
# (exits once a state file proves the wrapper ran), and leaves .command pristine.
# The persisted wrap above is the fallback: the NEXT session reads it at init.
SID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
if [ -n "$SID" ]; then
  STATE_FILE="$STATUSLINE_STATE_DIR/state-$SID.json"
  TRIES="${STATUSLINE_ACTIVATE_TRIES:-12}"
  INTERVAL="${STATUSLINE_ACTIVATE_INTERVAL:-4}"
  (
    i=0
    while [ "$i" -lt "$TRIES" ]; do
      sleep "$INTERVAL"
      [ -f "$STATE_FILE" ] && break   # wrapper ran — activated
      # Force a .statusLine.command content change (toggle a harmless trailing
      # shell comment) → settings-change event → hot-reload → wrapper picked up.
      t=$(mktemp "$PROJECT_DIR/.claude/.settings.XXXXXX" 2>/dev/null) || { i=$((i+1)); continue; }
      jq --arg n "$i" '
        if (.statusLine._statuslineInjectorWrapped == true) then
          .statusLine.command = ((.statusLine.command | sub(" #sli:[0-9]+$"; "")) + " #sli:" + $n)
        else . end
      ' "$P" > "$t" 2>/dev/null && mv -f "$t" "$P" 2>/dev/null || rm -f "$t" 2>/dev/null
      i=$((i+1))
    done
    # Strip the touch comment so .command is left pristine either way.
    t=$(mktemp "$PROJECT_DIR/.claude/.settings.XXXXXX" 2>/dev/null) || exit 0
    jq '
      if (.statusLine._statuslineInjectorWrapped == true) then
        .statusLine.command |= sub(" #sli:[0-9]+$"; "")
      else . end
    ' "$P" > "$t" 2>/dev/null && mv -f "$t" "$P" 2>/dev/null || rm -f "$t" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
fi

exit 0
