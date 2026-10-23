#!/usr/bin/env bash
# Model checking of the finality step (paper, section 10), plus the two
# mutants that show the passing checks are not vacuous.
#
#   TLA2TOOLS=/path/to/tla2tools.jar scripts/tlc.sh OUT_DIR
#
# Each run's TLC output goes to OUT_DIR/<model>.txt; scripts/summarize.py
# grades them. The n = 5 model is the same state machine as n = 4 with one
# equivocator (paper, section 10) and is not run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "${1:?output directory}" && cd "$1" && pwd)/tlc"
: "${TLA2TOOLS:?path to tla2tools.jar (TLC 2.19 or later)}"
: "${WORKERS:=16}"
mkdir -p "$OUT"
# -deadlock: the model covers two rounds of one height, so its runs end in
# states with no further step by design; those are not errors.
run() { # dir model
  ( cd "$1" && java -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers "$WORKERS" \
      -metadir "$1/states-$2" -config "$2.cfg" "$2.tla" ) >"$OUT/$3.txt" 2>&1 || true
  grep -E "No error has been found|is violated|distinct states found" "$OUT/$3.txt" | head -2 | sed "s/^/$3: /"
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$ROOT"/spec/* "$work/"
for m in MC_n3_f1_equivocating MC_n4_f1_equivocating MC_n4_f2_amnesic MC_n4_f2_amnesic_votes; do
  run "$work" "$m" "$m"
done

# Mutant 1: a quorum one smaller. Agreement must fail.
mkdir "$work/m1"; cp "$ROOT"/spec/* "$work/m1/"
sed -i 's/^Q      == N - F /Q      == N - F - 1 /' "$work/m1/SwarmFinality.tla"
grep -q 'N - F - 1' "$work/m1/SwarmFinality.tla"
run "$work/m1" MC_n4_f1_equivocating mutant_quorum_minus_one

# Mutant 2: a correct coordinator signs a final for every block, not only the
# one it decided. FinalAccountability must fail.
mkdir "$work/m2"; cp "$ROOT"/spec/* "$work/m2/"
sed -i 's/final'"'"' = final \\cup {\[src |-> p, v |-> m.v\]}/final'"'"' = final \\cup {[src |-> p, v |-> x] : x \\in Values}/' "$work/m2/SwarmFinality.tla"
grep -q 'x \\in Values}' "$work/m2/SwarmFinality.tla"
run "$work/m2" MC_n4_f2_amnesic mutant_final_any_block
