---
description: Revert the statusline-injector statusLine wrap in this project's settings.json (restore the original statusLine)
allowed-tools: Bash(bash:*)
---

Revert the statusline-injector wrap, restoring the original statusLine:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/statusline-uninstall.sh"`

Report the outcome above to the user in one line. Note that this only reverts the
statusLine entry in this project's `.claude/settings.json`; the shared wrapper and
state files under `~/.claude/statusline-injector/` are left in place because other
sessions may still use them, and `claude plugin uninstall statusline-injector`
removes the plugin itself.
