# OpenCode support (preview, not released)

Status: source + isolated proof. Wired to the iapeer capability lifecycle (not yet released), not
announced in the main README, not part of a tagged release. Tracks the iapeer
phase "OpenCode как полноценный агентский рантайм" (matrix row OC13).

## What it does

`statusline-plugin.mjs` is a native OpenCode server plugin. On every LLM request
the `experimental.chat.system.transform` hook appends ONE line to the system
prompt (it never replaces the agent prompt or other plugins' additions):

```
[st 17:20+03 · ctx(last) 60k/100k · 5h/7d n/a]
```

| Metric | Source | When absent |
|---|---|---|
| time | system clock + TZ | — |
| context | latest finished assistant message from the native `session.messages` API: `tokens.input+output+reasoning+cache.read+cache.write` (same formula as the OpenCode TUI) over the request model's `limit.context`. Shown above `SL_SHOW_PCT` (default 50). | `ctx n/a(<reason>)`: `no-usage` (no finished response yet, or the provider reported no usage — OpenCode turns that into zeros, which are NOT reported as an empty context), `response-error`, `compacted`, `model-change`, `window`, `api-error`, `session` |
| 5h / 7d | **not available**: OpenCode exposes per-message usage/cost, not subscription or provider quota windows. NVIDIA API usage is not Codex's 5h/7d. | always `5h/7d n/a` — never a fabricated 0% |

**PM decision 2026-10-17:** 5h/7d on OpenCode is a proven limitation and stays
`n/a`. The plugin does not make its own provider API calls to obtain quota
headers.

`ctx(last)` is the context of the previous completed request, not a forecast for
the current one. A failing native API is fail-open for the turn (`ctx n/a(api-error)`)
and visible once per failure streak via the native app log and a TUI toast; no
error bodies or credentials are copied into diagnostics.

## Install: iapeer capability lifecycle (iapeer docs/21)

The plugin is a registered iapeer **capability**; the core decides when and for
which peer it is provisioned, the plugin decides what is written.

```
node opencode/capability.mjs register     # install / update: declare + sweep every existing peer
node opencode/capability.mjs unregister   # uninstall: unprovision every endpoint, drop the declaration
node opencode/capability.mjs declaration  # print the declaration only
```

`register` writes the declaration to a temp file and runs
`iapeer capability register` (`iapeer` on PATH, or `IAPEER_CLI="bun …/src/cli/index.ts"`
for a sandbox; `IAPEER_ROOT` passes through). The declaration names
`runtimes: ["opencode"]` only — Claude/Codex surfaces come from the agfpd
marketplace plugin, not from this lifecycle. `command` is the absolute path of
the node that ran `register`, `args[0]` the absolute path of `provision.mjs`:
re-run `register` after a plugin update or a node relocation. Repair:
`iapeer capability sync statusline-injector`.

The core then calls, per `(peer, opencode)` endpoint:

```
node opencode/provision.mjs provision-peer   --personality <p> --runtime opencode --cwd <cwd> --private-dir <dir> --occasion birth|sweep-on
node opencode/provision.mjs unprovision-peer --personality <p> --runtime opencode --cwd <cwd> --private-dir <dir> --occasion remove|off-all
```

`--private-dir` is the core's `{privateDir}` placeholder (today
`<IAPEER_ROOT>/state/opencode/<p>/`). The plugin never derives that layout: without
the flag, or with a relative/non-normalized path, it refuses (exit 1). It writes only
`<dir>/statusline-injector-plugin.mjs` and
`statusline-injector.json` (`{"plugin":["file://…"]}`): atomic, idempotent (no
rewrite when unchanged), plugin before declaration, verified after write; exit 0
only when both are in place, otherwise exit 1 with the reason on stderr. A
per-peer `mkdir` lock serializes concurrent calls (stale after 120 s). Unprovision
removes only these two files. The core merges the fragment into
`OPENCODE_CONFIG_CONTENT` on launch only while the capability is registered; the
shared `cwd/opencode.json` is never touched. The core calls the commands only
once `opencode` is in `host.agent_runtimes` (with the iapeer OpenCode adapter).

## Reproduce the proof

```
bun opencode/e2e-probe.ts <path-to-opencode-1.19.3-binary>
```

Real `opencode serve`, fresh HOME/XDG, synthetic local OpenAI-compatible
provider with scripted usage (no network, no secrets). Checks the line on the
wire for: first turn (no usage), 60k/100k (shown), 10k/100k (hidden), provider
without usage (n/a, not zero); agent prompt preserved; unprovision cleanup.
