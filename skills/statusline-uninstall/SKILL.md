---
name: statusline-uninstall
description: Uninstall statusline-injector or revert its statusLine wrap (restore the original).
version: 0.1.0
---

# statusline-uninstall

Revert the statusline-injector statusLine wrap and restore the user's original
statusLine. The plugin's SessionStart hook (Claude Code only) wraps the
project-scope `statusLine.command` so it can capture subscription rate_limits;
this skill undoes that wrap.

## Runtime distinction

- **Claude Code** — the wrap lives in a project's `.claude/settings.json`. This
  skill reverts it.
- **Codex CLI** — statusline-injector uses no statusLine wrapper there (limits
  and context come from the session rollout). There is nothing to revert on
  Codex; only full plugin removal applies.

Note: the wrap is self-degrading — the wrapper sits at a stable path and keeps
passing the user's original statusLine through even if the plugin is removed, so
the terminal status line never breaks. Reverting is for a clean state, not to
prevent breakage.

## Revert the wrap (Claude Code)

Run the uninstall script. It restores the stashed original statusLine, or — when
the original was user-scope — removes the project entry so the harness falls
back to the untouched user-scope statusLine. It is idempotent and edits only the
`statusLine` entry in the target `settings.json`, never the user's own script.

Run it while the plugin is still installed (so the plugin root resolves):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT}}/scripts/statusline-uninstall.sh"
```

By default it targets `${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json`. To
revert a specific settings file, pass its path:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT}}/scripts/statusline-uninstall.sh" /path/to/.claude/settings.json
```

Relay the script's one-line outcome to the user. If it reports "not wrapped",
there was nothing to revert (already clean, or a Codex-only setup).

## Full plugin removal

After reverting (Claude), remove the plugin itself:

```bash
claude plugin uninstall statusline-injector     # Claude Code
codex plugin remove statusline-injector          # Codex CLI
```

The shared wrapper and per-session state under `~/.claude/statusline-injector/`
are left in place by the revert because other sessions may still use them;
delete that directory manually only when no session relies on it.
