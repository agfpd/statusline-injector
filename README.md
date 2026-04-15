Русская версия: [README.ru.md](./README.ru.md)

# statusline-injector

> A Claude Code hook that shows an LLM agent its own live status on
> every turn: time, model, session tokens, context window usage, and
> subscription burn.

**Platforms:** macOS, Linux.

## The problem: an agent that cannot see the clock

By default an LLM agent running under Claude Code has no idea
- what time it is right now,
- which model variant is actually serving the turn (`opus-4-6` vs
  `opus-4-6[1m]` — different context windows),
- how many tokens the current conversation already spent,
- how full the context window is,
- how close the Pro/Max subscription is to its 5-hour or 7-day reset.

The harness knows all of this. The agent does not — unless you put it
into the context explicitly.

The result is predictable: the agent plans as if time were infinite,
keeps loading more material into a context that is already 85% full,
and gets surprised when a long task dies mid-flight because the 5-hour
window just snapped shut.

## What it does

Two tiny shell scripts:

1. **`statusline-state-writer.sh`** — registered as the Claude Code
   `statusLine` command. The harness calls it with a JSON state blob
   on stdin before every turn. The writer persists that blob
   atomically to a state file (default: `~/.claude/statusline-injector/state.json`)
   and prints a compact one-liner to stdout for the terminal UI.

2. **`statusline-injector.sh`** — registered as a `UserPromptSubmit`
   hook. On every user turn it reads the live transcript JSONL
   (tokens, model, context size) + the persisted state file
   (subscription rate limits) and prints a status block to stdout.
   Claude Code injects that stdout into the agent's context.

The agent sees, at the top of every turn, something like:

```
[status @ 2026-04-15 18:24 +0300]
- model: claude-opus-4-6[1m]
- session: ↓12.3k / ↑4.1k tokens
- context: 8.1% of 1000k window
- subscription: 5h 5% (resets 23:00) / 7d 34% (resets 17.04)
```

When a subscription line crosses a threshold, it grows a marker:
`⚡` at 70% (watch), `⚠️` at 85% (close), `🔴` at 95% (critical).
Thresholds are configurable.

## Why this matters

Picture a person who doesn't know what time it is, whether it's
morning or evening, how long the conversation has been running, or
how much energy is left. They may be intelligent, but they cannot
be apt — there's nothing to orient against.

An LLM agent, by default, is exactly that. Every reply is
assembled from a vacuum, with no reference to the situation.
Giving it a clock, a sense of "how long I've been working," and
"how much budget is left" isn't cosmetic — it promotes a text
generator into a companion capable of reading the moment.

What then becomes possible:

- adapting tone to time of day,
- warning the user that the 5-hour subscription is nearing the
  limit — while there's still room to land the task cleanly,
- noticing the context is filling up and suggesting `/clear` or
  narrowing scope — before compaction lops off working memory,
- sensing the conversation is stuck and shifting approach.

Each of these behaviors has to live in the agent's own
instructions — the status block only supplies the data. But
without that data they're flatly impossible: the signal never
reaches the model.

## Quick start

> Requires: `bash`, `jq`, `awk`, `date`, `printf`.
> On macOS: `brew install jq`. On Debian/Ubuntu: `apt install jq`.

```sh
git clone https://github.com/agfpd/statusline-injector.git
cd statusline-injector
./install.sh
```

The installer is a small interactive wizard. It asks which fields to
show, what warning thresholds to use, where to keep the state file,
and offers to register the two hooks in your Claude Code
`settings.json` automatically (with a timestamped backup). You can
also skip registration and paste the printed snippet manually.

After the first Claude Code session restart the status block starts
appearing in the agent's context.

## Configuration

All behaviour is driven by env vars. The installer writes them to
`~/.claude/statusline-injector/config.env`; hooks source that file
before running.

```sh
# Where statusline-state-writer.sh persists the harness state
STATUSLINE_STATE_FILE="$HOME/.claude/statusline-injector/state.json"

# Title shown as [<title> @ YYYY-MM-DD HH:MM ±TZ]
STATUSLINE_TITLE="status"

# Toggle individual fields (1 = show, 0 = hide)
STATUSLINE_SHOW_TIME=1
STATUSLINE_SHOW_MODEL=1
STATUSLINE_SHOW_SESSION=1
STATUSLINE_SHOW_CONTEXT=1
STATUSLINE_SHOW_SUBSCRIPTION=1

# Warning thresholds for subscription lines (percent used)
# 70% → ⚡ watch    85% → ⚠️ close    95% → 🔴 critical
STATUSLINE_WATCH_5H=70
STATUSLINE_WARN_5H=85
STATUSLINE_CRIT_5H=95
STATUSLINE_WARN_7D=85
STATUSLINE_CRIT_7D=95
```

Edit the file directly or rerun `./install.sh` to regenerate it.

## Architecture

Two concerns, split in half:

- **`statusline-state-writer.sh`** owns the only field the
  UserPromptSubmit hook cannot reach on its own: `rate_limits`
  (Pro/Max subscription counters) and the exact model id with its
  `[1m]` suffix. The harness provides these only via the `statusLine`
  channel. The writer does one job — persist the blob atomically, so
  the injector never reads a half-written file.

- **`statusline-injector.sh`** is the presentation layer. It reads
  the transcript JSONL the harness points to and derives session
  tokens and last-turn context size from `message.usage` entries
  (`input_tokens + cache_read + cache_creation`, because cache_read
  still counts towards what the model actually sees). Context window
  is picked from the model id: `[1m]` → 1 000 000, everything else →
  200 000.

Design decisions worth knowing:

- `LC_ALL=C` is forced — under a `ru_RU`-style locale `awk`/`printf`
  would emit decimals with comma, and percentages break.
- State file writes go through `mktemp` + `mv` for atomicity.
- The injector exits 0 even on missing `jq` or absent state file —
  a status block is a nice-to-have, never a reason to block a turn.

## What this is NOT

- **Not telemetry.** Nothing leaves the machine. The state file
  lives under `$HOME`.
- **Not a scheduler or limiter.** It does not block turns, throttle
  the agent, or pause work. It only surfaces information the agent
  can act on — what the agent does with it is up to its system
  prompt.
- **Not accurate to the token.** Context percentage is derived from
  the last `usage` record in the transcript; during a tool-heavy turn
  it lags by one step. Good enough for "am I approaching the window"
  decisions, not good enough for precise budgeting.

## License

MIT. See [LICENSE](./LICENSE).

## Status

- [x] Core: state-writer + injector
- [x] Interactive installer
- [x] Configurable thresholds and field toggles
- [ ] Tests across shells and locales
- [ ] Linux install verified
- [ ] Plugin package for Claude Code
