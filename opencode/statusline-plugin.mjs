// Native OpenCode server plugin. No provider calls, credentials or core control.
// Keep a single export: OpenCode interprets every exported function as a plugin.
const count = (n) => Number.isSafeInteger(n) && n >= 0;
const compact = (n) => n < 1000 ? String(n) : `${Math.round(n / 1000)}k`;
const windowLabel = (n) => n < 1e6 ? compact(n) : `${Number((n / 1e6).toFixed(1))}m`;

function clock() {
  const d = new Date();
  const offset = -d.getTimezoneOffset();
  const pad = (n) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}${offset < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(offset) / 60))}${offset % 60 ? pad(Math.abs(offset) % 60) : ""}`;
}

function context(rows, model) {
  // Ignore the assistant placeholder for THIS request, not a finished response
  // without usage. Never search past a newer missing/error/compaction sample.
  const last = rows.map((r) => r.info)
    .filter((m) => m?.role === "assistant" && (m.finish || m.time?.completed || m.error))
    .sort((a, b) => (b.time?.created ?? 0) - (a.time?.created ?? 0) || String(b.id).localeCompare(String(a.id)))[0];
  if (!last) return { unavailable: "no-usage" };
  if (last.error) return { unavailable: "response-error" };
  if (last.summary) return { unavailable: "compacted" };
  if (last.providerID !== model?.providerID || last.modelID !== model?.id) return { unavailable: "model-change" };
  const t = last.tokens;
  const values = [t?.input, t?.output, t?.reasoning, t?.cache?.read, t?.cache?.write];
  // OpenCode normalizes absent provider usage to zero. Zero input+cache is not
  // evidence of an empty context; report unknown even if output was counted.
  if (!values.every(count) || t.input + t.cache.read + t.cache.write === 0) return { unavailable: "no-usage" };
  const used = values.reduce((a, b) => a + b, 0);
  if (!count(used)) return { unavailable: "no-usage" };
  const win = model?.limit?.context;
  if (!count(win) || win === 0) return { unavailable: "window" };
  return { used, win };
}

function render(sample) {
  let line = `st ${clock()}`;
  const configured = Number(process.env.SL_SHOW_PCT ?? 50);
  const threshold = Number.isFinite(configured) ? configured : 50;
  if (sample.unavailable) line += ` · ctx n/a(${sample.unavailable})`;
  else if (sample.used * 100 > sample.win * threshold) line += ` · ctx(last) ${compact(sample.used)}/${windowLabel(sample.win)}`;
  // Native OpenCode exposes usage, not the provider's subscription/quota caps.
  // In particular NVIDIA API usage is NOT Codex's 5h/7d subscription usage.
  return `[${line} · 5h/7d n/a]`;
}

export default async function StatuslineInjector({ client, directory }) {
  let lastFailure = "";
  async function diagnose(reason) {
    if (lastFailure === reason) return;
    lastFailure = reason;
    const message = `statusline-injector: ${reason}; context unavailable`;
    // Diagnostics must not hold up a request even if a diagnostic surface fails.
    await Promise.allSettled([
      client.app.log({ body: { service: "statusline-injector", level: "error", message }, signal: AbortSignal.timeout(300) }),
      client.tui.showToast({ body: { title: "statusline-injector", message, variant: "error" }, signal: AbortSignal.timeout(300) }),
    ]);
  }
  return {
    "experimental.chat.system.transform": async (input, output) => {
      let sample = { unavailable: "session" };
      try {
        if (input.sessionID) {
          const response = await client.session.messages({
            path: { id: input.sessionID },
            query: { directory, limit: 32 },
            signal: AbortSignal.timeout(1000),
          });
          if (response.error || !Array.isArray(response.data)) throw new Error("native messages API failed");
          sample = context(response.data, input.model);
          lastFailure = "";
        }
      } catch {
        sample = { unavailable: "api-error" };
        // Do not leak provider error bodies or credentials into diagnostics.
        try { await diagnose("native messages API failed"); } catch { /* fail open */ }
      }
      // Append; preserve agent.prompt, instructions and other plugins' additions.
      output.system.push(render(sample));
    },
  };
}
