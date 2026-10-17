#!/usr/bin/env node
// iapeer capability lifecycle command (iapeer docs/21). Not a runtime hook:
// fail loudly (exit 1, reason on stderr) unless the surfaces are in place.
//   provision.mjs provision-peer|unprovision-peer --personality P --runtime opencode
//                 --cwd DIR [--occasion birth|sweep-on|remove|off-all] [--root IAPEER_ROOT]
import { readFile, writeFile, mkdir, rename, rm, mkdtemp, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const NAME = "statusline-injector";
const OCCASIONS = ["birth", "sweep-on", "remove", "off-all"];
const LOCK_WAIT_MS = 30_000;
const LOCK_STALE_MS = 120_000; // = core per-call timeout: an older lock has no live owner

function parse(argv) {
  const [command, ...args] = argv;
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!["--personality", "--runtime", "--cwd", "--root", "--occasion"].includes(key) || !args[i + 1] || options[key]) throw new Error(`invalid argument ${JSON.stringify(key)}`);
    options[key] = args[i + 1];
  }
  if (!["provision-peer", "unprovision-peer"].includes(command) || !options["--cwd"] || !/^[a-z][a-z0-9-]{0,31}$/.test(options["--personality"] ?? "")) {
    throw new Error("usage: provision.mjs provision-peer|unprovision-peer --personality NAME --runtime opencode --cwd DIR [--occasion OCCASION] [--root IAPEER_ROOT]");
  }
  if (options["--runtime"] !== "opencode") throw new Error(`runtime ${JSON.stringify(options["--runtime"])} is not provisioned here (Claude/Codex use the agfpd plugin install)`);
  if (options["--occasion"] && !OCCASIONS.includes(options["--occasion"])) throw new Error(`unknown occasion ${JSON.stringify(options["--occasion"])}`);
  return { command, personality: options["--personality"], root: resolve(options["--root"] ?? process.env.IAPEER_ROOT ?? join(homedir(), ".iapeer")) };
}

// mkdir is atomic: one owner per peer dir. Stale lock (crashed owner) is reclaimed.
async function lock(dir) {
  const path = join(dir, `.${NAME}.lock`);
  const deadline = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try { await mkdir(path); return () => rm(path, { recursive: true, force: true }); } catch (e) { if (e.code !== "EEXIST") throw e; }
    try { if (Date.now() - (await stat(path)).mtimeMs > LOCK_STALE_MS) { await rm(path, { recursive: true, force: true }); continue; } } catch (e) { if (e.code === "ENOENT") continue; throw e; }
    if (Date.now() > deadline) throw new Error(`lock busy: ${path}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

const same = async (path, content) => { try { return (await readFile(path)).equals(Buffer.from(content)); } catch (e) { if (e.code === "ENOENT") return false; throw e; } };

async function main() {
  const { command, personality, root } = parse(process.argv.slice(2));
  const dir = join(root, "peers", personality, "opencode");
  const plugin = join(dir, `${NAME}-plugin.mjs`);
  const fragment = join(dir, `${NAME}.json`);

  if (command === "unprovision-peer") {
    try { await stat(dir); } catch (e) { if (e.code === "ENOENT") return; throw e; } // nothing of ours can exist
    const unlock = await lock(dir);
    try {
      // Declaration first: an interrupted removal never leaves a fragment pointing at nothing.
      await rm(fragment, { force: true });
      await rm(plugin, { force: true });
      for (const n of await readdir(dir)) if (n.startsWith(`.${NAME}-`)) await rm(join(dir, n), { recursive: true, force: true });
    } finally { await unlock(); }
    return;
  }

  const source = await readFile(join(dirname(fileURLToPath(import.meta.url)), "statusline-plugin.mjs"));
  const declaration = JSON.stringify({ plugin: [pathToFileURL(plugin).href] }, null, 2) + "\n";
  await mkdir(dir, { recursive: true });
  const unlock = await lock(dir);
  try {
    const staging = await mkdtemp(join(dir, `.${NAME}-`));
    try {
      const publish = async (path, content) => {
        if (await same(path, content)) return; // idempotent: no rewrite, no mtime churn
        const temp = join(staging, "next");
        await writeFile(temp, content, { mode: 0o600 });
        await rename(temp, path);
      };
      // Plugin first, declaration last: an interrupted install never declares an absent plugin.
      await publish(plugin, source);
      await publish(fragment, declaration);
    } finally { await rm(staging, { recursive: true, force: true }); }
    // Exit 0 only when the surfaces are verifiably in place.
    if (!(await same(plugin, source)) || !(await same(fragment, declaration))) throw new Error(`surfaces not in place after write: ${dir}`);
  } finally { await unlock(); }
}

main().catch((e) => { console.error(`${NAME} provision: ${e.message}`); process.exitCode = 1; });
