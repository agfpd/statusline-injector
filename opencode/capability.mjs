#!/usr/bin/env node
// Installer side of the iapeer capability lifecycle (iapeer docs/21).
//   capability.mjs declaration         print the declaration JSON
//   capability.mjs register            write it to a temp file + `iapeer capability register`
//   capability.mjs unregister          `iapeer capability unregister statusline-injector`
// The iapeer CLI is `iapeer` on PATH, or IAPEER_CLI (space-separated argv, e.g.
// "bun /path/to/iapeer/src/cli/index.ts") for a sandbox. IAPEER_ROOT passes through.
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const NAME = "statusline-injector";
const here = dirname(fileURLToPath(import.meta.url));

function declaration() {
  const { version } = JSON.parse(readFileSync(join(here, "..", ".claude-plugin", "plugin.json"), "utf8"));
  const tail = (verb) => [join(here, "provision.mjs"), verb, "--personality", "{personality}", "--runtime", "{runtime}", "--cwd", "{cwd}", "--private-dir", "{privateDir}", "--occasion", "{occasion}"];
  return {
    schema: 1,
    capability: NAME,
    package: `@agfpd/${NAME}`,
    version,
    // OpenCode only. Claude/Codex surfaces are the agfpd marketplace plugin
    // (its own install/update path); provisioning them here would be a no-op
    // that claims surfaces it never created.
    runtimes: ["opencode"],
    // Absolute node: launchd's minimal PATH resolves nothing.
    provision: { command: process.execPath, args: tail("provision-peer") },
    unprovision: { command: process.execPath, args: tail("unprovision-peer") },
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
  if (verb === "unregister") return iapeer(["capability", "unregister", NAME]);
  if (verb === "register") {
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
