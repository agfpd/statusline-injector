#!/usr/bin/env bash
# Release script for statusline-injector.
#
# No npm package — release-flow is a shell script, by analogy with the other
# non-npm agfpd plugins (Persistent-Peer). The ONE release command per the team
# plugin standard (§9): everything below is the cloud release (repo →
# marketplace); local rollout is a separate, universal mechanism.
#
# Steps:
#   1. Bump version in .claude-plugin/plugin.json + .codex-plugin/plugin.json.
#   2. Commit + annotated tag (vX.Y.Z).
#   3. Push with --follow-tags.
#   4. node scripts/bump-marketplace.cjs — update agfpd-marketplace with the
#      new ref+sha (Claude + Codex manifests) and push it.
#
# Usage:
#   ./scripts/release.sh           # patch (default)
#   ./scripts/release.sh patch|minor|major
set -euo pipefail

LEVEL="${1:-patch}"
case "$LEVEL" in
  patch|minor|major) ;;
  *) echo "Usage: $0 [patch|minor|major]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

# Tree must be clean — otherwise the release tags unrelated changes.
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree dirty — commit or stash before release" >&2
  git status --short
  exit 1
fi

CURRENT=$(node -p 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version')

NEW=$(node -e "
  const [M,m,p] = '$CURRENT'.split('.').map(Number);
  const level = '$LEVEL';
  if (level === 'major') console.log((M+1)+'.0.0');
  else if (level === 'minor') console.log(M+'.'+(m+1)+'.0');
  else console.log(M+'.'+m+'.'+(p+1));
")

echo "Releasing v${CURRENT} → v${NEW} (${LEVEL})"
echo ""

# Bump version in BOTH manifests (Claude + Codex), kept in lockstep.
node -e "
  const fs = require('fs');
  for (const p of ['.claude-plugin/plugin.json', '.codex-plugin/plugin.json']) {
    if (fs.existsSync(p)) {
      const j = JSON.parse(fs.readFileSync(p,'utf8'));
      j.version = '$NEW';
      fs.writeFileSync(p, JSON.stringify(j,null,2)+'\n');
      console.log('updated', p);
    }
  }
"

git add .claude-plugin/plugin.json .codex-plugin/plugin.json
git commit -m "$NEW"
# Annotated tag (-a): `git push --follow-tags` only pushes annotated tags.
git tag -a "v${NEW}" -m "v${NEW}"
git push origin main --follow-tags

echo ""
echo "=== Bumping agfpd-marketplace ==="
node scripts/bump-marketplace.cjs

echo ""
echo "✔ Released statusline-injector v${NEW}"
