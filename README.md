Русская версия: [README.ru.md](./README.ru.md)

# statusline-injector

> A plug-and-play plugin for **Claude Code** and **Codex CLI** that injects an
> agent's own live status into its context on every turn — system time, the
> 5h/7d subscription limits, and how full the context window is — as one
> minimal line.

**Platforms:** macOS, Linux. **Runtimes:** Claude Code, Codex CLI.

## The problem: an agent that cannot see the clock

By default an LLM agent has no idea
- what time it is right now,
- how full its context window already is,
- how close its Pro/Max (or ChatGPT) subscription is to the 5-hour or 7-day reset.

The harness knows all of this. The agent does not — unless it is put into the
context explicitly. The result is predictable: the agent plans as if time were
infinite, keeps loading material into a context that is already 85% full, and
is surprised when a long task dies mid-flight because the 5-hour window just
snapped shut.

## What the agent sees

One line, at the top of every turn:

```
[st 14:30+03 · ctx 70k/200k · 5h 42% · 7d 18%]
```

When a limit nears its threshold, that window expands with its reset time and a
marker — and only then:

```
[st 14:30+03 · ctx 188k/200k · 5h 92%→19:00 ⚠️ · 7d 18%]
```

- `st HH:MM±TZ` — system local time with the system timezone offset (never
  hardcoded; falls back to UTC).
- `ctx used/window` — context occupancy as a token count over the window size
  (e.g. `70k/200k`, `420k/1m`).
- `5h` / `7d` — the two subscription rate-limit windows, percent used.

The line is deliberately tiny. On Claude the injected context accumulates in
the transcript turn after turn, so every extra token is a recurring tax on the
whole fleet — minimality is the design.

## Why this matters

Picture a person who doesn't know what time it is, how long the conversation
has been running, or how much energy is left. They may be intelligent, but they
cannot be apt — there's nothing to orient against. An LLM agent, by default, is
exactly that.

Giving it a clock and a sense of "how much budget is left" isn't cosmetic — it
lets the agent warn the user that the 5-hour window is nearing its limit while
there's still room to land the task, notice the context filling up and suggest
narrowing scope before compaction lops off working memory, and adapt to the
moment. Each of those behaviors lives in the agent's own instructions — the
status line only supplies the data. Without it, they're flatly impossible: the
signal never reaches the model.

## Install

Distributed through the `agfpd` plugin marketplace. Installation is
plug-and-play — no manual steps, no post-install wiring.

**Claude Code** (project scope):

```sh
claude plugin marketplace update agfpd
claude plugin install statusline-injector@agfpd --scope project
```

**Codex CLI** (global — Codex applies plugins per host):

```sh
codex plugin marketplace upgrade agfpd
codex plugin add statusline-injector@agfpd
```

Restart the session (or `/reload-plugins` in interactive Claude Code) and the
line starts appearing on every turn.

To try it without installing, dev-load it for one session:
`claude --plugin-dir /path/to/statusline-injector`.

> Requires `jq` on `PATH`. macOS: `brew install jq`. Debian/Ubuntu:
> `apt install jq`. If `jq` is missing the plugin degrades silently — it never
> blocks a turn.

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
`settings.json`.

**Codex — no wrapper.** Everything (limits and context) already lives in the
session rollout, so the same `UserPromptSubmit` hook reads it directly. No
statusLine interception.

## Configuration

Driven by env vars (all optional):

```sh
# Where the per-session state + the stable wrapper live (Claude).
STATUSLINE_STATE_DIR="$HOME/.claude/statusline-injector"

# Percent at which a limit window expands with its reset time + ⚠️.
SL_WARN_PCT=80
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
even if the plugin is removed without reverting.

## What this is NOT

- **Not telemetry.** Nothing leaves the machine. State lives under `$HOME`.
- **Not a scheduler or limiter.** It never blocks turns or throttles the agent;
  it only surfaces information the agent can act on.
- **Not accurate to the token.** Context lags by one step during a tool-heavy
  turn — good enough for "am I approaching the window," not for precise
  budgeting.

## License

MIT. See [LICENSE](./LICENSE).
