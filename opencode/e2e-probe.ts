// Isolated end-to-end proof on a REAL native OpenCode: provision → launch with
// the fragment merged into OPENCODE_CONFIG_CONTENT (as the iapeer core does) →
// synthetic local provider captures the wire system prompt per turn.
// No network, no fleet secrets, fresh HOME/XDG. Usage: bun opencode/e2e-probe.ts <opencode-binary>
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
const opencode = process.argv[2];
if (!opencode) throw new Error("usage: bun e2e-probe.ts <opencode-binary>");
const here = dirname(new URL(import.meta.url).pathname);
const root = mkdtempSync(join(tmpdir(), "sli-opencode-e2e-"));
const iapeerRoot = join(root, "iapeer"), cwd = join(root, "cwd"), home = join(root, "home");
const privateDir = join(iapeerRoot, "state/opencode/probe"); // core-owned layout, passed as {privateDir}
for (const d of [iapeerRoot, cwd, home]) mkdirSync(d);
const run = (args: string[]) => Bun.spawnSync(["node", join(here, "provision.mjs"), ...args], { stderr: "pipe" });
const pv = run(["provision-peer", "--personality", "probe", "--runtime", "opencode", "--cwd", cwd, "--private-dir", privateDir]);
if (pv.exitCode !== 0) throw new Error("provision failed: " + pv.stderr);
const fragment = JSON.parse(readFileSync(join(privateDir, "statusline-injector.json"), "utf8"));
// Scripted per-request provider usage (OpenAI-compatible stream).
const usages: (object | null)[] = [
  { prompt_tokens: 60000, completion_tokens: 100, total_tokens: 60100 },
  { prompt_tokens: 10000, completion_tokens: 50, total_tokens: 10050 },
  null,
  { prompt_tokens: 80000, completion_tokens: 10, total_tokens: 80010 },
];
const wire: any[] = [];
const provider = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(req) {
  const body = await req.json();
  const isTitle = JSON.stringify(body.messages ?? []).includes("title");
  const usage = isTitle ? null : usages[wire.length];
  if (!isTitle) wire.push(body);
  const id = "c" + Date.now();
  const ev: any[] = [{ id, object: "chat.completion.chunk", created: 1, model: "synthetic", choices: [{ index: 0, delta: { role: "assistant", content: "SYNTHETIC_OK" }, finish_reason: null }] },
    { id, object: "chat.completion.chunk", created: 1, model: "synthetic", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], ...(usage ? { usage } : {}) }];
  return new Response(ev.map((x) => "data: " + JSON.stringify(x) + "\n\n").join("") + "data: [DONE]\n\n", { headers: { "Content-Type": "text/event-stream" } });
} });
writeFileSync(join(root, "doctrine.txt"), "PROBE_DOCTRINE\n");
const config = { model: "synthetic/synthetic", small_model: "synthetic/synthetic", enabled_providers: ["synthetic"], autoupdate: false, share: "disabled",
  plugin: [...fragment.plugin], agent: { iapeer: { mode: "primary", prompt: "{file:" + join(root, "doctrine.txt") + "}" } }, default_agent: "iapeer",
  provider: { synthetic: { npm: "@ai-sdk/openai-compatible", name: "Synthetic", options: { baseURL: provider.url.toString() + "v1", apiKey: "not-a-secret" },
    models: { synthetic: { name: "Synthetic", limit: { context: 100000, output: 1000 } } } } } };
const env = { HOME: home, PATH: process.env.PATH!, TZ: process.env.TZ ?? "Europe/Moscow", XDG_CONFIG_HOME: join(home, "config"), XDG_DATA_HOME: join(home, "data"),
  XDG_CACHE_HOME: join(home, "cache"), XDG_STATE_HOME: join(home, "state"), OPENCODE_CONFIG_CONTENT: JSON.stringify(config),
  OPENCODE_DISABLE_DEFAULT_PLUGINS: "true", OPENCODE_DISABLE_MODELS_FETCH: "true", OPENCODE_DISABLE_SHARE: "true", PEER_IDENTITY: "opencode-probe" };
const s = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("") }); const port = s.port; s.stop(true);
const p = Bun.spawn([opencode, "serve", "--hostname", "127.0.0.1", "--port", String(port), "--print-logs"], { cwd, env, stdout: Bun.file(join(root, "stdout.log")), stderr: Bun.file(join(root, "stderr.log")) });
const url = "http://127.0.0.1:" + port;
let fail = 0;
const check = (name: string, ok: boolean, got: string) => { console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${got}`); if (!ok) fail++; };
try {
  for (let i = 0; ; i++) { if (i > 150 || p.exitCode !== null) throw new Error("readiness failed"); try { if ((await fetch(url + "/global/health")).ok) break; } catch {} await Bun.sleep(200); }
  const session = await (await fetch(url + "/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title: "probe" }) })).json();
  for (const t of ["ONE", "TWO", "THREE", "FOUR"])
    await (await fetch(`${url}/session/${session.id}/message`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ agent: "iapeer", parts: [{ type: "text", text: "USER_" + t }] }) })).text();
  const lines = wire.map((b) => { const sys = b.messages.filter((m: any) => m.role === "system").map((m: any) => typeof m.content === "string" ? m.content : JSON.stringify(m.content)).join("\n");
    return { doctrine: sys.includes("PROBE_DOCTRINE"), line: (sys.match(/\[st [^\]]*\]/g) ?? []) }; });
  const want = [/^\[st \d\d:\d\d[+-]\d{2,4} · ctx n\/a\(no-usage\) · 5h\/7d n\/a\]$/, /^\[st \d\d:\d\d[+-]\d{2,4} · ctx\(last\) 60k\/100k · 5h\/7d n\/a\]$/,
    /^\[st \d\d:\d\d[+-]\d{2,4} · 5h\/7d n\/a\]$/, /^\[st \d\d:\d\d[+-]\d{2,4} · ctx n\/a\(no-usage\) · 5h\/7d n\/a\]$/];
  check("requests captured", wire.length === 4, String(wire.length));
  lines.forEach((l, i) => { check(`turn ${i + 1} doctrine kept`, l.doctrine, String(l.doctrine)); check(`turn ${i + 1} line`, l.line.length === 1 && want[i].test(l.line[0]), JSON.stringify(l.line)); });
} finally { p.kill(); await p.exited; provider.stop(true); }
const un = run(["unprovision-peer", "--personality", "probe", "--runtime", "opencode", "--cwd", cwd, "--private-dir", privateDir]);
check("unprovision removes surfaces", un.exitCode === 0 && !existsSync(join(privateDir, "statusline-injector.json")) && !existsSync(join(privateDir, "statusline-injector-plugin.mjs")), String(un.exitCode));
if (fail) console.log("artifacts kept: " + root); else rmSync(root, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
