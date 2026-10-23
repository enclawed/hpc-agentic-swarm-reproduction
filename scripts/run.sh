#!/usr/bin/env bash
# Re-run the paper's experiments and grade them.
#
#   scripts/run.sh [tlc] [e1] [e2] [e3] [e6]      (default: all of them)
#
# Results go to results/rerun (OUT_DIR to change); scratch files to a fresh
# directory under WORK_BASE (default: a new temporary directory). Ends by
# printing the graded summary of results/rerun.
#
# Needs: scripts/setup.sh done; LAMMPS with MPI (LMP, the lmp binary); MPICH
# with Hydra (MPI_BIN, the directory holding mpiexec); Python 3; for tlc a
# Java runtime and TLA2TOOLS; for e6 Ollama with the model in MODEL (default
# gemma4:latest) and a GPU that holds it. See README.md for versions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(mkdir -p "${OUT_DIR:-$ROOT/results/rerun}" && cd "${OUT_DIR:-$ROOT/results/rerun}" && pwd)"
WORK_BASE="${WORK_BASE:-$(mktemp -d)}"
export REPO="${REPO:-$ROOT/enclawed-oss}"
test -f "$REPO/enclawed.mjs" || { echo "run scripts/setup.sh first" >&2; exit 2; }
git -C "$REPO" log -1 --format='%H' >"$OUT_DIR/enclawed-oss-commit.txt" 2>/dev/null || true
cd "$ROOT"
for x in ${@:-tlc e1 e2 e3 e6}; do
  echo "=== $x (scratch: $WORK_BASE/$x)"
  case "$x" in
    tlc) scripts/tlc.sh "$OUT_DIR" ;;
    e1) WORK="$WORK_BASE/e1" OUT="$OUT_DIR/e1.csv" COUNTS="${COUNTS:-16}" bash experiments/e1-overhead.sh ;;
    e2) WORK="$WORK_BASE/e2" OUT="$OUT_DIR/redteam.jsonl" bash experiments/redteam.sh ;;
    e3) WORK="$WORK_BASE/e3" OUT="$OUT_DIR/e3-growth.jsonl" bash experiments/growth.sh ;;
    e6)
      WORK="$WORK_BASE/e6" OUT="$OUT_DIR/agents-scenarios.jsonl" bash experiments/agents/agents.sh
      for s in a1 a2 a3; do
        python3 experiments/agents/analyze.py "$WORK_BASE/e6/$s" >"$OUT_DIR/agents-$s.json"
      done ;;
    *) echo "unknown experiment: $x" >&2; exit 2 ;;
  esac
done
python3 scripts/summarize.py "$OUT_DIR"
