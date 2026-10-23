#!/usr/bin/env bash
# Publish the committed tree of this repository to the public mirror as one
# orphan commit on `main`: the same files, the enclawed-oss submodule pinned to
# the same public snapshot, and no history. The private source (`origin`) and
# the local branch are not touched.
#
#   git remote add public git@github.com:enclawed/hpc-agentic-swarm-reproduction.git
#   scripts/publish-public.sh [--yes]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git remote get-url public >/dev/null
if [ -n "$(git status --porcelain --untracked-files=no -- . ':!enclawed-oss')" ]; then
  echo "commit or discard local changes first: the snapshot is the committed tree" >&2
  exit 1
fi
tree=$(git rev-parse 'HEAD^{tree}')
pin=$(git ls-tree HEAD enclawed-oss | awk '{print $3}')
echo "snapshot of $(git log -1 --format='%h %s')"
echo "enclawed-oss pinned at ${pin:0:9}"
if [ "${1:-}" != "--yes" ]; then
  read -r -p "publish to $(git remote get-url public)? [y/N] " ok
  [ "$ok" = y ] || exit 1
fi
commit=$(git commit-tree "$tree" -m "Snapshot $(date +%Y-%m-%d)")
git push --force public "$commit:refs/heads/main"
echo "published $commit"
