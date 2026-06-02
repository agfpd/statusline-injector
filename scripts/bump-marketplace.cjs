#!/usr/bin/env node
// scripts/bump-marketplace.cjs
//
// Run from the release flow (after `git push --follow-tags`) — updates the
// agfpd-marketplace manifests (Claude + Codex) with this plugin's new ref+sha
// and pushes the marketplace repo.
//
// AGFPD_MARKETPLACE_PATH — path to the local marketplace clone
// (default ~/Projects/agfpd-marketplace).
//
// Idempotent: if ref+sha already match, the git diff is empty and the commit
// is skipped. Safe to run repeatedly.
"use strict";

const fs = require("fs");
const path = require("path");
const { execSync, spawnSync } = require("child_process");

// Per-plugin config — the only thing that changes when copied to another plugin.
const PLUGIN_NAME = "statusline-injector"; // name in marketplace.json (case-sensitive)
const REPO_NAME = "statusline-injector";   // part after agfpd/ in the github URL

const REPO_OWNER = "agfpd";
const MARKETPLACE_DIR = process.env.AGFPD_MARKETPLACE_PATH
  || path.join(process.env.HOME, "Projects/agfpd-marketplace");

function shCapture(cmd, opts = {}) {
  return execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts })
    .toString().trim();
}
function shInherit(cmd, opts = {}) {
  execSync(cmd, { stdio: "inherit", ...opts });
}

function getVersion(pluginRepoDir) {
  for (const candidate of [
    path.join(pluginRepoDir, ".claude-plugin/plugin.json"),
    path.join(pluginRepoDir, "package.json"),
  ]) {
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, "utf8")).version;
    }
  }
  throw new Error("Cannot find version: no .claude-plugin/plugin.json or package.json");
}

function getSha(pluginRepoDir) {
  return shCapture("git rev-parse HEAD", { cwd: pluginRepoDir });
}

function updateManifest(filepath, version, sha) {
  if (!fs.existsSync(filepath)) {
    console.log(`  Skip ${filepath}: not found`);
    return false;
  }
  const data = JSON.parse(fs.readFileSync(filepath, "utf8"));
  const entry = (data.plugins || []).find((p) => p.name === PLUGIN_NAME);
  if (!entry) {
    console.log(`  Skip ${filepath}: plugin "${PLUGIN_NAME}" not in catalog`);
    return false;
  }
  // Explicit semver in the catalog entry, kept in sync with ref by this bump
  // (§8). A missing entry version leaves the SHA-fallback open, which sorts
  // sha-named cache snapshots ABOVE real releases.
  entry.version = version;
  entry.source = {
    source: "url",
    url: `https://github.com/${REPO_OWNER}/${REPO_NAME}.git`,
    ref: `v${version}`,
    sha,
  };
  fs.writeFileSync(filepath, JSON.stringify(data, null, 2) + "\n", "utf8");
  return true;
}

function main() {
  if (!fs.existsSync(MARKETPLACE_DIR)) {
    console.error(`agfpd-marketplace not found at: ${MARKETPLACE_DIR}`);
    console.error("Set AGFPD_MARKETPLACE_PATH or clone the repo first.");
    process.exit(1);
  }
  const pluginRepo = process.cwd();
  const version = getVersion(pluginRepo);
  const sha = getSha(pluginRepo);

  console.log(`Bumping ${PLUGIN_NAME} → v${version} (${sha.slice(0, 12)}) in marketplace`);

  try {
    shInherit("git pull origin main --rebase --autostash", { cwd: MARKETPLACE_DIR });
  } catch (e) {
    console.warn("warning: git pull --rebase failed, proceeding with local state");
  }

  const claudeUpdated = updateManifest(
    path.join(MARKETPLACE_DIR, ".claude-plugin/marketplace.json"),
    version, sha
  );
  const codexUpdated = updateManifest(
    path.join(MARKETPLACE_DIR, ".agents/plugins/marketplace.json"),
    version, sha
  );

  if (!claudeUpdated && !codexUpdated) {
    console.log("No manifests to update — plugin not in any catalog.");
    return;
  }

  const status = shCapture("git status --porcelain", { cwd: MARKETPLACE_DIR });
  if (!status) {
    console.log(`✔ ${PLUGIN_NAME} already at v${version} ${sha.slice(0, 12)} in marketplace`);
    return;
  }

  shInherit(
    "git add .claude-plugin/marketplace.json .agents/plugins/marketplace.json",
    { cwd: MARKETPLACE_DIR }
  );
  const msg = `bump ${PLUGIN_NAME} to v${version}\n\nref: v${version}\nsha: ${sha}`;
  const commitRes = spawnSync("git", ["commit", "-m", msg], {
    cwd: MARKETPLACE_DIR, stdio: "inherit",
  });
  if (commitRes.status !== 0) {
    throw new Error(`git commit failed (exit ${commitRes.status})`);
  }
  shInherit("git push origin main", { cwd: MARKETPLACE_DIR });
  console.log(`✔ Bumped ${PLUGIN_NAME} → v${version} (${sha.slice(0, 12)}) in agfpd-marketplace`);
}

main();
