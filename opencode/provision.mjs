#!/usr/bin/env node
// Provisioning is NOT a runtime hook: fail loudly before publishing a fragment.
import { readFile, mkdir, rename, rm, mkdtemp } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!["--personality", "--runtime", "--cwd", "--root"].includes(key) || !args[i + 1] || options[key]) throw new Error("invalid arguments");
    options[key] = args[i + 1];
  }
  if (!["provision-peer", "unprovision-peer"].includes(command) || options["--runtime"] !== "opencode" || !options["--cwd"] || !/^[a-z0-9][a-z0-9_-]*$/.test(options["--personality"] ?? "")) {
    throw new Error("usage: provision.mjs provision-peer|unprovision-peer --personality NAME --runtime opencode --cwd DIR [--root IAPEER_ROOT]");
  }
  const root = resolve(options["--root"] ?? process.env.IAPEER_ROOT ?? join(homedir(), ".iapeer"));
  const dir = join(root, "peers", options["--personality"], "opencode");
  const plugin = join(dir, "statusline-injector-plugin.mjs");
  const fragment = join(dir, "statusline-injector.json");
  if (command === "unprovision-peer") {
    await rm(fragment, { force: true });
    await rm(plugin, { force: true });
    return;
  }
  const source = await readFile(join(dirname(fileURLToPath(import.meta.url)), "statusline-plugin.mjs"));
  await mkdir(dir, { recursive: true });
  const staging = await mkdtemp(join(dir, ".statusline-injector-"));
  try {
    const { writeFile } = await import("node:fs/promises");
    async function publish(path, content) {
      try { if ((await readFile(path)).equals(Buffer.from(content))) return; } catch (e) { if (e.code !== "ENOENT") throw e; }
      const temp = join(staging, "next");
      await writeFile(temp, content, { mode: 0o600 });
      await rename(temp, path);
    }
    // Plugin first, declaration last. Interrupted install never declares an
    // absent plugin; repeat provision to converge after an interrupted update.
    await publish(plugin, source);
    await publish(fragment, JSON.stringify({ plugin: [pathToFileURL(plugin).href] }, null, 2) + "\n");
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}
main().catch((e) => { console.error(`statusline-injector provision: ${e.message}`); process.exitCode = 1; });
