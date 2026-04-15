#!/usr/bin/env bash
# statusline-injector — interactive installer.
#
# Walks the user through field selection, writes a config.env to
# $HOME/.claude/statusline-injector/, and optionally registers the two hooks
# in Claude Code's settings.json.

set -eu

# --- constants ---
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECTOR="$REPO_DIR/statusline-injector.sh"
WRITER="$REPO_DIR/statusline-state-writer.sh"

DEFAULT_CONFIG_DIR="$HOME/.claude/statusline-injector"
DEFAULT_STATE_FILE="$DEFAULT_CONFIG_DIR/state.json"
DEFAULT_SETTINGS="$HOME/.claude/settings.json"

# --- pretty ---
bold()   { printf '\033[1m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m' "$*"; }
green()  { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }
red()    { printf '\033[31m%s\033[0m' "$*"; }

# --- ask helpers ---
# ask_yn PROMPT DEFAULT(Y|N) → echoes 1 or 0
ask_yn() {
  local prompt="$1" default="$2" ans hint="[Y/n]"
  [ "$default" = "N" ] && hint="[y/N]"
  while :; do
    read -r -p "$prompt $hint: " ans
    ans="${ans:-$default}"
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) echo 1; return ;;
      [Nn]|[Nn][Oo])     echo 0; return ;;
      *) echo "  please answer y or n" >&2 ;;
    esac
  done
}

# ask_str PROMPT DEFAULT → echoes value
ask_str() {
  local prompt="$1" default="$2" ans
  read -r -p "$prompt [$default]: " ans
  echo "${ans:-$default}"
}

# --- preflight ---
[ -f "$INJECTOR" ] || { red "error:"; echo " $INJECTOR not found"; exit 1; }
[ -f "$WRITER" ]   || { red "error:"; echo " $WRITER not found"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  red "error:"; echo " jq is required but not found in PATH."
  echo "install it first:"
  echo "  macOS:  brew install jq"
  echo "  Debian: sudo apt install jq"
  exit 1
fi

chmod +x "$INJECTOR" "$WRITER"

# --- banner ---
echo
bold "statusline-injector setup"; echo
echo "-------------------------"
echo "Shows a Claude Code LLM agent its own live status on every turn:"
echo "time, model, tokens, context usage, and subscription burn."
echo

# --- prompts ---
bold "What to show in the injected status block?"; echo
SHOW_TIME=$(ask_yn         "  show current time?                   " Y)
SHOW_MODEL=$(ask_yn        "  show model id?                       " Y)
SHOW_SESSION=$(ask_yn      "  show session tokens?                 " Y)
SHOW_CONTEXT=$(ask_yn      "  show context window usage?           " Y)
SHOW_SUBSCRIPTION=$(ask_yn "  show subscription limits (Pro/Max)?  " Y)

echo
bold "Formatting"; echo
TITLE=$(ask_str "  display title (shown as [<title> @ ...])" "status")

if [ "$SHOW_SUBSCRIPTION" = "1" ]; then
  echo
  bold "Warning thresholds (subscription %)"; echo
  WATCH_5H=$(ask_str "  5h watch  ⚡" "70")
  WARN_5H=$(ask_str  "  5h warn   ⚠️" "85")
  CRIT_5H=$(ask_str  "  5h crit   🔴" "95")
  WARN_7D=$(ask_str  "  7d warn   ⚠️" "85")
  CRIT_7D=$(ask_str  "  7d crit   🔴" "95")
else
  WATCH_5H=70; WARN_5H=85; CRIT_5H=95; WARN_7D=85; CRIT_7D=95
fi

echo
bold "Storage"; echo
STATE_FILE=$(ask_str "  state file path" "$DEFAULT_STATE_FILE")
CONFIG_DIR="$(dirname "$STATE_FILE")"
CONFIG_FILE="$CONFIG_DIR/config.env"

# --- write config ---
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

cat > "$CONFIG_FILE" <<EOF
# statusline-injector config — written by install.sh on $(date '+%Y-%m-%d %H:%M:%S %z')
# Re-run ./install.sh to regenerate, or edit this file directly.

STATUSLINE_STATE_FILE="$STATE_FILE"
STATUSLINE_TITLE="$TITLE"

STATUSLINE_SHOW_TIME=$SHOW_TIME
STATUSLINE_SHOW_MODEL=$SHOW_MODEL
STATUSLINE_SHOW_SESSION=$SHOW_SESSION
STATUSLINE_SHOW_CONTEXT=$SHOW_CONTEXT
STATUSLINE_SHOW_SUBSCRIPTION=$SHOW_SUBSCRIPTION

STATUSLINE_WATCH_5H=$WATCH_5H
STATUSLINE_WARN_5H=$WARN_5H
STATUSLINE_CRIT_5H=$CRIT_5H
STATUSLINE_WARN_7D=$WARN_7D
STATUSLINE_CRIT_7D=$CRIT_7D
EOF
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

echo
green "✓"; echo " config written to $CONFIG_FILE"

# --- settings.json registration ---
echo
bold "Register hooks in Claude Code settings.json?"; echo
dim "  This adds statusLine + UserPromptSubmit entries pointing to this install."; echo
REGISTER=$(ask_yn "  register now?" Y)

if [ "$REGISTER" = "1" ]; then
  SETTINGS=$(ask_str "  settings.json path" "$DEFAULT_SETTINGS")
  SETTINGS_DIR="$(dirname "$SETTINGS")"
  mkdir -p "$SETTINGS_DIR"

  # Wrap each hook in a tiny shell that sources config.env first so env vars
  # from the wizard take effect.
  WRAP_WRITER="bash -c 'set -a; . \"$CONFIG_FILE\"; set +a; exec \"$WRITER\"'"
  WRAP_INJECTOR="bash -c 'set -a; . \"$CONFIG_FILE\"; set +a; exec \"$INJECTOR\"'"

  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"
    green "✓"; echo " backup saved as ${SETTINGS}.bak.*"
  else
    echo '{}' > "$SETTINGS"
  fi

  TMP_SETTINGS="$(mktemp)"
  # Marker substring used to detect prior installs of this tool.
  # Using the injector script filename — it's fixed across installations
  # even if the user clones the repo into a different directory name.
  INSTALL_MARKER="statusline-injector.sh"
  jq \
    --arg writer   "$WRAP_WRITER" \
    --arg injector "$WRAP_INJECTOR" \
    --arg marker   "$INSTALL_MARKER" \
    '. as $root
     | .statusLine = {"type":"command","command":$writer}
     | .hooks = (.hooks // {})
     # Idempotency: strip any UserPromptSubmit command that references this
     # installer (from a previous run), then append the current one. Any
     # unrelated hook groups and commands stay intact. Empty groups (where
     # the only hook was ours) are dropped so we do not leave empty slots.
     | .hooks.UserPromptSubmit = (
         ((.hooks.UserPromptSubmit // [])
            | map(.hooks |= ((. // []) | map(select((.command // "") | contains($marker) | not))))
            | map(select((.hooks // []) | length > 0)))
         + [{"hooks":[{"type":"command","command":$injector}]}]
       )
    ' "$SETTINGS" > "$TMP_SETTINGS"

  mv "$TMP_SETTINGS" "$SETTINGS"
  green "✓"; echo " hooks registered in $SETTINGS"
else
  echo
  yellow "skipped."; echo " to register manually, add to your Claude Code settings.json:"
  cat <<EOF

  "statusLine": {
    "type": "command",
    "command": "bash -c 'set -a; . \"$CONFIG_FILE\"; set +a; exec \"$WRITER\"'"
  },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash -c 'set -a; . \"$CONFIG_FILE\"; set +a; exec \"$INJECTOR\"'" } ] }
    ]
  }

EOF
fi

echo
green "done."; echo " first Claude Code session will pick it up."
echo
dim "  edit config later: $CONFIG_FILE"; echo
dim "  reinstall / reconfigure: ./install.sh"; echo
