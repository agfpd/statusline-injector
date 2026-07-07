# Changelog

All notable changes to **statusline-injector** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.5] - 2026-07-07

### Fixed

- `hooks/hooks.json` no longer carries a top-level `description` key. Codex's
  strict (serde `deny_unknown_fields`) hooks parser rejected the whole file —
  `unknown field \`description\`, expected \`hooks\`` — so **no** statusline
  hooks (`SessionStart`, `UserPromptSubmit`) loaded on Codex peers at all;
  Claude silently ignored the key. The file now has only the `hooks` key, which
  both runtimes accept. The removed prose is redundant with the hook
  descriptions already in `README.md` / `README.ru.md`. Verified against the
  real Codex CLI 0.142.5 parser (buggy shape reproduces the exact error; fixed
  shape loads clean); Claude is unaffected (the `hooks` block is byte-identical
  and the key was already ignored).

## [0.1.4] - 2026-06-20

### Removed

- Legacy `[1m]`/`-1m` model-id context-window derivation (transition-debt audit
  item A2). Modern Claude (≥ v2.1.132) delivers
  `context_window.context_window_size` (200000 / 1000000) directly in the
  `statusLine` blob, so the window size — 1m models included — now comes straight
  from the state blob. The unknown-window case falls back to a plain 200k default.

## [0.1.3] - 2026-06-11

### Fixed

- statusLine self-wrap detection is now content-based instead of marker-only. A
  wrapped command whose `_statuslineInjector*` marker keys were stripped by an
  external settings rewrite was being mistaken for an original and re-wrapped,
  nesting one wrapper level per session (observed up to 5 levels across 14 fleet
  configs) and poisoning the saved original. Detection now recognizes the wrapper
  by command content and recursively unwraps wrapper, quoting, and stash layers
  back to the true original, healing any already-poisoned config on the next run.
- `SessionStart` skips the settings write when the wrapped content is unchanged,
  avoiding needless file-watcher churn; a re-run is now a true no-op.
- Uninstall recognizes and reverts marker-less wrapped entries.

## [0.1.2] - 2026-06-02

### Fixed

- The statusLine wrap now activates within the same session. Claude can resolve
  `statusLine.command` before the freshly written wrap is picked up, leaving the
  5h/7d limits absent until the next session. A detached activator now forces
  Claude's mid-session statusLine hot-reload until the wrapper runs, so the
  limits appear the same session; the persisted wrap remains the next-session
  fallback.

## [0.1.1] - 2026-06-02

### Fixed

- Codex runtime detection by the `rollout-*.jsonl` transcript basename, robust to
  a custom `CODEX_HOME` and to Codex exporting `CLAUDE_PLUGIN_ROOT`; the hook's
  `transcript_path` is preferred as the rollout. Verified live in an interactive
  Codex session.
- `SessionStart` is now an explicit no-op under Codex, so no stray
  `.claude/settings.json` is ever written there.

### Changed

- The uninstall affordance is a skill (`statusline-uninstall`) instead of a slash
  command, so it works in both runtimes (Codex does not run slash commands).
- Plugin manifest description trimmed to ≤ 200 characters; hook matcher set to
  `*` on both hook groups.

## [0.1.0] - 2026-06-02

### Added

- Initial plug-and-play plugin for **Claude Code** and **Codex CLI** that injects
  one minimal status line into the agent's context every turn — system time with
  timezone, the 5h/7d subscription limits, and context-window fill, e.g.
  `[st 14:30+03 · ctx 70k/200k · 5h 42% · 7d 18%]`. A limit nearing its threshold
  expands with its reset time and a warning marker.
- Claude: a `SessionStart` hook idempotently wraps the project-scope
  `statusLine.command` to capture the harness blob (`rate_limits` +
  `context_window`) into a per-session state file, passing the user's original
  statusLine through untouched; `UserPromptSubmit` renders the line from state,
  with a transcript fallback for context.
- Codex: `UserPromptSubmit` reads the session rollout directly (`rate_limits`,
  `last_token_usage`, `model_context_window`) — no statusLine wrapper.
- Reversible wrap that edits only the `settings.json` command string (stable
  wrapper path, forward-only materialization) plus a `statusline-uninstall`
  affordance.

### Changed

- Reworked the earlier standalone two-script tool (state-writer + injector +
  `install.sh`) into the plugin above.

[0.1.5]: https://github.com/agfpd/statusline-injector/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/agfpd/statusline-injector/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/agfpd/statusline-injector/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/agfpd/statusline-injector/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/agfpd/statusline-injector/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/agfpd/statusline-injector/releases/tag/v0.1.0
