#!/usr/bin/env node
// Installer side of the iapeer capability lifecycle (iapeer docs/21).
//   capability.mjs declaration         print the declaration JSON
//   capability.mjs register            install the runtime files to the STABLE dir, then
//                                      `iapeer capability register` (sweeps every peer)
//   capability.mjs unregister          `iapeer capability unregister statusline-injector`,
//                                      then remove the stable dir
// The declaration points at the stable dir, never at this checkout or a versioned
// plugin cache (that can be garbage-collected after an update and would leave the
// core calling a missing file). STATUSLINE_OPENCODE_HOME overrides the stable dir.
// The iapeer CLI is `iapeer` on PATH, or IAPEER_CLI (space-separated argv, e.g.
// "bun /path/to/iapeer/src/cli/index.ts") for a sandbox. IAPEER_ROOT passes through.
import { readFileSync, mkdtempSync, writeFileSync, rmSync, mkdirSync, copyFileSync, renameSync, existsSync, accessSync, constants } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir, homedir } from "node:os";
import { dirname, join, delimiter, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

const NAME = "statusline-injector";
const here = dirname(fileURLToPath(import.meta.url));
const FILES = ["provision.mjs", "statusline-plugin.mjs"]; // provision.mjs reads the plugin next to itself
const stableDir = () => process.env.STATUSLINE_OPENCODE_HOME || join(homedir(), ".local", "share", NAME, "opencode");
const version = () => JSON.parse(readFileSync(join(here, "..", ".claude-plugin", "plugin.json"), "utf8")).version;

// A PATH entry (e.g. /opt/homebrew/bin/node) survives a node upgrade; the realpath
// in process.execPath (…/Cellar/node/<ver>/bin/node) does not.
function nodeBin() {
  for (const d of (process.env.PATH ?? "").split(delimiter)) {
    if (!isAbsolute(d)) continue;
    try { accessSync(join(d, "node"), constants.X_OK); return join(d, "node"); } catch { /* next */ }
  }
  return process.execPath;
}

function install(dir) {
  mkdirSync(dir, { recursive: true });
  for (const f of FILES) {
    const temp = join(dir, `.${f}.next`);
    copyFileSync(join(here, f), temp);
    renameSync(temp, join(dir, f));
  }
  writeFileSync(join(dir, "VERSION"), version() + "\n");
}

function declaration(dir = stableDir()) {
  const tail = (verb) => [join(dir, "provision.mjs"), verb, "--personality", "{personality}", "--runtime", "{runtime}", "--cwd", "{cwd}", "--private-dir", "{privateDir}", "--occasion", "{occasion}"];
  return {
    schema: 1,
    capability: NAME,
    package: `@agfpd/${NAME}`,
    version: version(),
    // OpenCode only. Claude/Codex surfaces are the agfpd marketplace plugin
    // (its own install/update path); provisioning them here would be a no-op
    // that claims surfaces it never created.
    runtimes: ["opencode"],
    // Absolute node: launchd's minimal PATH resolves nothing.
    provision: { command: nodeBin(), args: tail("provision-peer") },
    unprovision: { command: nodeBin(), args: tail("unprovision-peer") },
  };
}

function iapeer(args) {
  const base = process.env.IAPEER_CLI ? process.env.IAPEER_CLI.split(" ").filter(Boolean) : ["iapeer"];
  const r = spawnSync(base[0], [...base.slice(1), ...args], { stdio: "inherit" });
  if (r.error) throw new Error(`cannot run ${base[0]}: ${r.error.message}`);
  return r.status ?? 1;
}

function main() {
  const verb = process.argv[2];
  if (verb === "declaration") { process.stdout.write(JSON.stringify(declaration(), null, 2) + "\n"); return 0; }
  if (verb === "unregister") {
    // Unprovision runs FROM the stable dir: remove it only after the core is done.
    const status = iapeer(["capability", "unregister", NAME]);
    if (status === 0 && existsSync(stableDir())) rmSync(stableDir(), { recursive: true, force: true });
    return status;
  }
  if (verb === "register") {
    install(stableDir());
    const dir = mkdtempSync(join(tmpdir(), `${NAME}-decl-`));
    try {
      const file = join(dir, `${NAME}.json`); // core requires capability == file stem
      writeFileSync(file, JSON.stringify(declaration(), null, 2) + "\n");
      return iapeer(["capability", "register", file]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
  console.error("usage: capability.mjs declaration|register|unregister");
  return 2;
}

try { process.exitCode = main(); } catch (e) { console.error(`${NAME} capability: ${e.message}`); process.exitCode = 1; }
