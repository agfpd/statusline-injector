Русская версия: [README.ru.md](./README.ru.md)

# statusline-injector

**A drop-in plugin for Claude Code and Codex CLI that injects an agent's own live status into its context on every turn.**

The injected status is one minimal line: system time, the 5h/7d subscription limits, and how full the context window is.

**Platforms:** macOS, Linux. **Runtimes:** Claude Code, Codex CLI, OpenCode (via iapeer).

## The problem: an agent that cannot see the clock

By default an LLM agent has no idea
- what time it is right now,
- how full its context window already is,
- how close its Pro/Max (or ChatGPT) subscription is to the 5-hour or 7-day reset.

The harness knows all of this. The agent does not — unless that information is explicitly placed in
its context. The result is predictable: the agent plans as if time were
infinite, keeps loading material into a context that is already 85% full, and
is surprised when a long task dies mid-flight because the 5-hour window just
snapped shut.

## What the agent sees

One line, at the top of every turn. The clock is always there; context and the
subscription limits appear only when they start to matter — each is shown once
it passes the halfway mark of its own budget, and then as a plain number, never
an alarm. On a healthy turn that's the whole line:

```
[st 14:30+03]
```

As the context window or a limit window fills past 50%, its segment appears —
still a bare fact:

```
[st 14:30+03 · ctx 150k/200k · 5h 62%]
```

- `st HH:MM±TZ` — system local time with the system timezone offset (never
  hardcoded; falls back to UTC). **Always shown.**
- `ctx used/window` — context occupancy as a token count over the window size
  (e.g. `150k/200k`, `620k/1m`). Shown only once occupancy passes 50% of the
  window.
- `5h` / `7d` — the two subscription rate-limit windows, percent used. Each
  shown only once it passes 50%.

The metrics are deliberately quiet. Below the halfway mark they are hidden
entirely; above it they are bare numbers — no reset countdown, no warning
marker, nothing to fixate on. The goal is a signal the agent can act on near a
boundary, not a running meter it narrates every turn. And the line is tiny by
design: on Claude the injected context accumulates in the transcript turn after
turn, so every token saved below the threshold is a recurring tax spared the
whole fleet.

## Why this matters

An agent that can't see the clock or its remaining budget has nothing to orient
against. Give it both, and it can act: warn the user that the 5-hour window is
nearing its limit while there's still room to land the task, notice the context
filling up and suggest narrowing scope before compaction lops off working
memory, and adapt to the moment.

Each of those behaviors lives in the agent's own instructions — the status line
only supplies the data. Without it, they're impossible: the signal never reaches
the model.

## Install

This public repository is also a plugin marketplace. No GitHub account or
access to the private fleet marketplace is needed. Installation is
plug-and-play — no manual wiring after install.

**Claude Code** (project scope):

```sh
claude plugin marketplace add https://github.com/agfpd/statusline-injector.git
claude plugin install statusline-injector@statusline-injector --scope project
```

**Codex CLI** (global — Codex applies plugins per host):

```sh
codex plugin marketplace add https://github.com/agfpd/statusline-injector.git
codex plugin add statusline-injector@statusline-injector
```

The public catalog pins a released version, not development `main`. To update:
refresh the marketplace (`claude plugin marketplace update statusline-injector`
or `codex plugin marketplace upgrade statusline-injector`), then run
`claude plugin update statusline-injector@statusline-injector` or repeat
`codex plugin add statusline-injector@statusline-injector`, and restart.
Existing fleet installations through `statusline-injector@agfpd` stay supported;
use one marketplace per installation to avoid duplicate hooks.

**OpenCode** (as an [iapeer](https://github.com/agfpd/iapeer) agent runtime;
needs iapeer ≥ 0.4.117 and `node` on `PATH`):

```sh
git clone --depth 1 --branch v0.3.0 https://github.com/agfpd/statusline-injector
node statusline-injector/opencode/capability.mjs register
```

`register` copies the OpenCode plugin to a stable directory and registers it as
an iapeer capability; iapeer then provisions every existing OpenCode peer and
each new one. The new line takes effect on the peer's next launch. On OpenCode
the 5h/7d limits always read `n/a`: OpenCode exposes per-message usage, not
subscription windows. Uninstall: `node statusline-injector/opencode/capability.mjs unregister`.
Details: [`opencode/README.md`](opencode/README.md).

Restart the session (or `/reload-plugins` in interactive Claude Code) and the
line starts appearing on every turn. If Codex asks to review plugin hooks,
review and approve them; an update can require approval again. Project scope
keeps it easy to try: if you
decide against it, the [`statusline-uninstall`](#uninstall) skill reverses the
whole loop — it touches nothing but the `statusLine` command string.

> Requires `jq` on `PATH`. macOS: `brew install jq`. Debian/Ubuntu:
> `apt install jq`. Hooks remain non-blocking if `jq` is missing; when the
> plugin owns the Claude terminal line, that line shows a visible install
> diagnostic instead of going blank.

## How it works

The two runtimes deliver the data differently, so the plugin reads each at its
own source. The injected line is identical.

| Data | Claude Code | Codex CLI |
|---|---|---|
| Time | system clock, system TZ | same |
| Context / window | statusLine blob (`context_window`), transcript fallback | rollout `token_count` (`last_token_usage.input_tokens` / `model_context_window`) |
| 5h / 7d limits | **only** the `statusLine` stdin (harness push) | rollout `token_count` (`rate_limits.primary` / `secondary`) |

**Claude — wrap, don't replace.** The subscription `rate_limits` reach the
system on exactly one channel: the JSON the harness pipes to the `statusLine`
command. They are not in the transcript or any file. So a `SessionStart` hook
idempotently **wraps** the project-scope `statusLine.command`: the wrapper
captures that blob into a per-session state file, then passes the same stdin to
the user's original statusLine command and echoes its stdout verbatim — the
user's terminal status line is preserved untouched. The `UserPromptSubmit` hook
reads the state file and renders the line. The wrap is reversible and never
edits the contents of the user's script — only the command string in
`settings.json`. That command also contains a dependency-free inline guard: if
the stable wrapper is missing or cannot run, the terminal shows
`[statusline-injector BROKEN: wrapper missing; reinstall plugin]` instead of a
blank status line. The guard remains effective even if the plugin hook and
cache are gone.

**Codex — no wrapper.** Everything (limits and context) already lives in the
session rollout, so the same `UserPromptSubmit` hook reads it directly. No
statusLine interception.

## Configuration

Driven by env vars (all optional):

```sh
# Where the per-session state + the stable wrapper live (Claude).
STATUSLINE_STATE_DIR="$HOME/.claude/statusline-injector"

# Percent of a metric's budget above which it appears in the line. Below this,
# context and the 5h/7d limits are hidden; the clock is always shown.
SL_SHOW_PCT=50

# Values outside 0–100 or malformed values fall back to 50.
# Codex respects CODEX_HOME (default: "$HOME/.codex") when locating rollouts.

# Retention for the per-session state files (Claude). On every session start,
# state files untouched for longer than this are deleted; a live session
# rewrites its own file on every render, so only dead sessions are collected.
# Set to 0 to keep everything.
STATUSLINE_STATE_TTL_DAYS=7
```

## Uninstall

The Claude statusLine wrap is fully reversible. Ask the agent to "uninstall
statusline-injector" or "revert the statusline wrap" — the bundled
`statusline-uninstall` skill (works in both runtimes) restores your original
statusLine. Or run the script directly:

```
bash "$CLAUDE_PLUGIN_ROOT/scripts/statusline-uninstall.sh" [settings.json]
```

It restores the original statusLine (or removes our entry so the harness falls
back to the untouched user-scope one). Codex uses no wrapper, so there is
nothing to revert there. Then remove the plugin itself with
`claude plugin uninstall statusline-injector` / `codex plugin remove`. The wrap
is self-degrading anyway — the wrapper keeps your original statusLine working
even if the plugin is removed without reverting; if the stable wrapper itself
is lost, the inline guard makes the failure visible.

## What this is NOT

- **Not telemetry.** Nothing leaves the machine. State lives under `$HOME`.
- **Not a scheduler or limiter.** It never blocks turns or throttles the agent;
  it only surfaces information the agent can act on.
- **Not accurate to the token.** Context lags by one step during a tool-heavy
  turn — good enough for "am I approaching the window," not for precise
  budgeting.

## Tests

The offline regression suite requires Python 3, Bash and jq; the plugin itself
still requires only Bash and jq:

```sh
python3 -m unittest discover -s tests -v
```

It covers partial transcripts, separate context/limit events, custom Codex homes,
thresholds, fail-open behavior, wrapper healing, uninstall and atomic updates.
For live verification, use an isolated project and interactive Claude/Codex
sessions; confirm the injected line on a second turn after usage is available.

The public catalogs (`.claude-plugin/marketplace.json` and
`.agents/plugins/marketplace.json`) intentionally pin the same published tag and
commit SHA. After publishing a release, update both catalogs' `version`,
`source.ref` and `source.sha` together in a follow-up commit. A tag must exist
before the catalogs point to it; no self-referential commit SHA is needed.

## License

MIT. See [LICENSE](./LICENSE).
