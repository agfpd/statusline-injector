# OpenCode support (preview, not released)

Status: source + isolated proof. Not wired into iapeer automatically yet, not
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

`ctx(last)` is the context of the previous completed request, not a forecast for
the current one. A failing native API is fail-open for the turn (`ctx n/a(api-error)`)
and visible once per failure streak via the native app log and a TUI toast; no
error bodies or credentials are copied into diagnostics.

## Install ABI (agreed with iapeer core, 2026-10-17)

```
node opencode/provision.mjs provision-peer   --personality <p> --runtime opencode --cwd <cwd> [--root <IAPEER_ROOT>]
node opencode/provision.mjs unprovision-peer --personality <p> --runtime opencode --cwd <cwd> [--root <IAPEER_ROOT>]
```

Writes only `<root>/peers/<p>/opencode/statusline-injector-plugin.mjs` and
`statusline-injector.json` (`{"plugin":["file://…"]}`), atomic and idempotent,
plugin before declaration. The core merges the fragment into
`OPENCODE_CONFIG_CONTENT` on launch; the shared `cwd/opencode.json` is never
touched. Install errors exit non-zero. Automatic invocation from iapeer
create/add-runtime is an OPEN core item (no generic capability-lifecycle entry
exists yet) — manual provisioning is a test path, not the supported install.

## Reproduce the proof

```
bun opencode/e2e-probe.ts <path-to-opencode-1.19.3-binary>
```

Real `opencode serve`, fresh HOME/XDG, synthetic local OpenAI-compatible
provider with scripted usage (no network, no secrets). Checks the line on the
wire for: first turn (no usage), 60k/100k (shown), 10k/100k (hidden), provider
without usage (n/a, not zero); agent prompt preserved; unprovision cleanup.
