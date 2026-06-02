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

WRAPPED=$(jq -r '.statusLine._statuslineInjectorWrapped // false' "$SETTINGS" 2>/dev/null || echo false)
if [ "$WRAPPED" != "true" ]; then
  echo "statusline-injector: statusLine in $SETTINGS is not wrapped — nothing to revert."
  exit 0
fi

TMP=$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX" 2>/dev/null) || { echo "mktemp failed" >&2; exit 0; }
jq '
  if (.statusLine._statuslineInjectorWrapped == true) then
    (.statusLine._statuslineInjectorOriginalSource) as $src
    | (.statusLine._statuslineInjectorOriginal) as $orig
    | if ($src == "project" and $orig != null) then
        .statusLine = $orig
      else
        del(.statusLine)
      end
  else . end
' "$SETTINGS" > "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$SETTINGS" 2>/dev/null \
  && echo "statusline-injector: reverted statusLine in $SETTINGS." \
  || { rm -f "$TMP" 2>/dev/null; echo "statusline-injector: revert failed (left $SETTINGS untouched)." >&2; }

exit 0
