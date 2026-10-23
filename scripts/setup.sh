#!/usr/bin/env bash
# Prepare the enclawed-oss checkout every experiment runs against: the
# enclawed-oss submodule, pinned to the public snapshot the results were
# produced with. Installs its dependencies and builds it (the agents in E6 run
# the built CLI). Needs Node 22+, pnpm 10, git.
#
#   scripts/setup.sh
#
# To run against another checkout instead, set REPO for scripts/run.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$ROOT" submodule update --init enclawed-oss
DEST="$ROOT/enclawed-oss"
echo "enclawed-oss: $(git -C "$DEST" log -1 --format='%h %s')"
( cd "$DEST" && CI=true pnpm install --frozen-lockfile && pnpm build )
test -f "$DEST/enclawed.mjs"
echo "ready: $DEST"
