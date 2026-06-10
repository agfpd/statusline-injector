#!/usr/bin/env bash
# statusline-injector — reverse the statusLine wrap.
#
# Restores a project-scope settings.json to the state before the wrapper was
# installed:
#   - original was project-scope → restore the stashed original verbatim;
#   - original was user-scope / none → remove our project entry, so the harness
#     falls back to the untouched user-scope statusLine (or none).
#
# Idempotent and safe: only edits the given settings.json. It does NOT remove
# the shared stable wrapper / state files — other sessions or peers may still
# rely on them. Re-running on an already-clean file is a no-op.
#
# Usage:
#   statusline-uninstall.sh [path/to/settings.json]
# Default target: $CLAUDE_PROJECT_DIR/.claude/settings.json, else
# $PWD/.claude/settings.json.

set -u
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 0; }

SETTINGS="${1:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json}"
if [ ! -f "$SETTINGS" ]; then
  echo "statusline-injector: no settings.json at $SETTINGS — nothing to revert."
  exit 0
fi

# Self-wrap detection + unwrap, CONTENT-based (marker keys can be stripped by
# external settings rewrites; a poisoned stash can itself contain a wrap).
# Keep these defs in sync with statusline-session-start.sh.
WRAPPER="${STATUSLINE_STATE_DIR:-$HOME/.claude/statusline-injector}/wrapper.sh"
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

WRAPPED=$(jq -r --arg w "$WRAPPER" "$SLI_JQ_DEFS"'
  (.statusLine // null) as $cur
  | ($cur != null) and
    (($cur._statuslineInjectorWrapped == true)
     or (($cur.command // "") | sli_ours))
' "$SETTINGS" 2>/dev/null || echo false)
if [ "$WRAPPED" != "true" ]; then
  echo "statusline-injector: statusLine in $SETTINGS is not wrapped — nothing to revert."
  exit 0
fi

TMP=$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX" 2>/dev/null) || { echo "mktemp failed" >&2; exit 0; }
jq --arg w "$WRAPPER" "$SLI_JQ_DEFS"'
  .statusLine as $cur
  | if ($cur._statuslineInjectorWrapped == true) then
      # Marked wrap: restore the stash for a project-scope original (unwrapped
      # to the TRUE original — the stash itself may contain a wrap), else drop
      # our entry so the harness falls back to user-scope.
      ( if ($cur._statuslineInjectorOriginalSource == "project")
        then ($cur._statuslineInjectorOriginal | sli_orig)
        else null end ) as $orig
      | if $orig != null then .statusLine = $orig else del(.statusLine) end
    elif (($cur.command // "") | sli_ours) then
      # Marker-less wrap (marker stripped by an external rewrite): unwrap the
      # command itself; an empty result (bare wrapper) means no real original.
      ($cur | sli_orig) as $orig
      | if $orig != null then .statusLine = $orig else del(.statusLine) end
    else . end
' "$SETTINGS" > "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$SETTINGS" 2>/dev/null \
  && echo "statusline-injector: reverted statusLine in $SETTINGS." \
  || { rm -f "$TMP" 2>/dev/null; echo "statusline-injector: revert failed (left $SETTINGS untouched)." >&2; }

exit 0
