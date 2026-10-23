#!/usr/bin/env bash
# E1: cost of supervising every MPI rank through the swarm.
# Alternates bare mpiexec and the enclawed shim, REPS times per rank count and
# per accelerator, and records LAMMPS loop time, end-to-end wall time and
# supervisor CPU.
#
# ACCELS picks where LAMMPS computes: cpu (every rank on its own core) and gpu
# (the same ranks, the force computation offloaded to GPU 0 through the GPU
# package: -sf gpu -pk gpu 1). The runtime's own work is the same in both; the
# GPU shortens the compute loop, so the share the supervision takes is larger.
set -euo pipefail
source "$(dirname "$0")/env.sh"
REPS="${REPS:-3}"; STEPS="${STEPS:-2000}"; COUNTS="${COUNTS:-16 28}"
ACCELS="${ACCELS:-cpu gpu}"
OUT="${OUT:-$WORK/e1.csv}"
accel_args() { [ "$1" = gpu ] && echo "-sf gpu -pk gpu 1" || true; }
for a in $ACCELS; do
  case "$a" in
    cpu) ;;
    gpu) grep -q '^GPU package API' <<<"$("$LMP" -h 2>/dev/null)" || { echo "LMP has no GPU package" >&2; exit 2; } ;;
    *) echo "unknown accelerator: $a" >&2; exit 2 ;;
  esac
done
make_bin; swarm_up 10000 1000
echo "accel,ranks,mode,rep,loop_s,wall_s,admit_ms,lease_ms_max,supervisor_cpu_ms_mean,blocks" >"$OUT"
cd "$WORK"
for n in $COUNTS; do
  for rep in $(seq 1 "$REPS"); do
    for accel in $ACCELS; do
      # shellcheck disable=SC2046 # the accelerator's options are separate words
      set -- $(accel_args "$accel")
      for mode in bare swarm; do
        log="$WORK/e1-$accel-$n-$mode-$rep.log"
        start=$(date +%s.%N)
        if [ "$mode" = bare ]; then
          "$MPI_BIN/mpiexec" -n "$n" "$LMP" -in "$EXP/in.lj.long" -var steps "$STEPS" -log none "$@" >"$log" 2>&1
        else
          env "PATH=$SHIMS:$PATH" mpiexec -n "$n" "$LMP" -in "$EXP/in.lj.long" -var steps "$STEPS" -log none "$@" >"$log" 2>&1
        fi
        end=$(date +%s.%N)
        loop=$(grep -oP 'Loop time of \K[0-9.]+' "$log")
        wall=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')
        admit=$(grep -oP '"event":"job.admitted".*"ms":\K[0-9]+' "$log" || echo "")
        lease=$(grep -oP '"event":"rank.leased".*"ms":\K[0-9]+' "$log" | sort -n | tail -1 || echo "")
        cpu=$(grep -oP '"supervisorCpuMs":\K[0-9]+' "$log" | awk '{s+=$1} END {if (NR) printf "%.0f", s/NR}' || true)
        blocks=$(grep -oP '"event":"rank.exit".*"blocks":\K[0-9]+' "$log" | sort -n | tail -1 || echo "")
        echo "$accel,$n,$mode,$rep,$loop,$wall,$admit,$lease,$cpu,$blocks" | tee -a "$OUT"
      done
    done
  done
done
swarm_down
