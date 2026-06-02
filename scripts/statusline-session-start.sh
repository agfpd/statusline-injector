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

# --- Claude-only gate. Codex sets neither of these; bail clean there. ---
if [ -z "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Drain stdin (session_id, cwd, …) — not required, but keep the pipe clean.
HOOK_INPUT=""
if [ ! -t 0 ]; then HOOK_INPUT=$(cat 2>/dev/null || true); fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
: "${STATUSLINE_STATE_DIR:=$HOME/.claude/statusline-injector}"
WRAPPER="$STATUSLINE_STATE_DIR/wrapper.sh"

mkdir -p "$STATUSLINE_STATE_DIR" 2>/dev/null || true

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
TMP=$(mktemp "$PROJECT_DIR/.claude/.settings.XXXXXX" 2>/dev/null || true)
[ -n "$TMP" ] || exit 0

jq \
  --arg w "$WRAPPER" \
  --argjson u "$USER_ST" \
  '
  .statusLine as $cur
  | (
      if ($cur != null and $cur._statuslineInjectorWrapped == true) then
        if ($cur._statuslineInjectorOriginalSource == "project") then
          { obj: $cur._statuslineInjectorOriginal, src: "project" }
        elif ($u != null and (($u.command // "") != "")) then
          { obj: $u, src: "user" }
        else
          { obj: null, src: "none" }
        end
      elif ($cur != null and (($cur.command // "") != "")) then
        { obj: $cur, src: "project" }
      elif ($u != null and (($u.command // "") != "")) then
        { obj: $u, src: "user" }
      else
        { obj: null, src: "none" }
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
  && mv -f "$TMP" "$P" 2>/dev/null \
  || rm -f "$TMP" 2>/dev/null

exit 0
