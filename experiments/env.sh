# Paths for the swarm experiments. Source this; override any variable first.
# REPO is the enclawed-oss checkout that scripts/setup.sh prepares.
: "${REPO:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/enclawed-oss}"
: "${WORK:?set WORK to an empty working directory}"
: "${LMP:=$HOME/.local/lammps-sp-mpi/build/lmp}"
: "${MPI_BIN:=$HOME/.local/enclawed-hpc-venv/bin}"
: "${RANKS:=28}"
: "${COORDS:=4}"
: "${BASE_PORT:=7800}"
export REPO WORK LMP MPI_BIN RANKS COORDS BASE_PORT
EXP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EXP
SWARM="$WORK/bin/swarm"
SHIMS="$WORK/shims"
SW="$WORK/swarm"
export SWARM SHIMS SW
# The launcher the experiments start jobs with; a site file may add options.
: "${MPI_LAUNCH:=mpiexec}"

# The swarm command, independent of the caller's working directory.
make_bin() {
  mkdir -p "$WORK/bin" "$SHIMS"
  cat > "$SWARM" <<EOS
#!/bin/sh
exec node --import "$REPO/node_modules/tsx/dist/esm/index.mjs" "$REPO/src/enclawed/swarm/cli.ts" "\$@"
EOS
  chmod +x "$SWARM"
  # Site shims: mpiexec/mpirun resolve here and wrap every rank in `swarm rank`.
  for name in mpiexec mpirun; do
    cat > "$SHIMS/$name" <<EOS
#!/bin/sh
exec "$SWARM" launch --dir "$SW" --rank-bin "$SWARM" \${SWARM_LAUNCH_FLAGS:-} -- "$MPI_BIN/mpiexec" "\$@"
EOS
    chmod +x "$SHIMS/$name"
  done
}

# swarm_init [init flags]: a new swarm in $SW, coordinators at $BASE_PORT up.
swarm_init() {
  "$SWARM" init --dir "$SW" --base-port "$BASE_PORT" "$@" 2>>"$WORK/init.log"
}

# swarm_up [lease_ms] [heartbeat_ms]: fresh swarm with $COORDS coordinators.
swarm_up() {
  local lease="${1:-10000}" hb="${2:-1000}"
  rm -rf "$SW"; mkdir -p "$SW"
  swarm_init --coordinators "$COORDS" --lease-ms "$lease" --heartbeat-ms "$hb"
  for ((i = 0; i < COORDS; i++)); do
    nohup "$SWARM" coordinator --dir "$SW" --index "$i" >"$SW/coord-$i.log" 2>&1 &
    echo $! >"$SW/coord-$i.pid"
  done
  # Wait for the first few blocks.
  for _ in $(seq 1 100); do
    if [ "$(grep -c '"event":"block"' "$SW/coord-0.log" 2>/dev/null)" -ge 2 ]; then return 0; fi
    sleep 0.1
  done
  echo "swarm did not start" >&2; return 1
}

coord_kill() { kill -9 "$(cat "$SW/coord-$1.pid")" 2>/dev/null || true; }
coord_start() {
  nohup "$SWARM" coordinator --dir "$SW" --index "$1" >>"$SW/coord-$1.log" 2>&1 &
  echo $! >"$SW/coord-$1.pid"
}
swarm_down() {
  for ((i = 0; i < COORDS; i++)); do coord_kill "$i"; done
}

# job_kill_all NAME: end a job that cannot finish on its own (R11).
job_kill_all() {
  pkill -KILL -P "$JOB_PID" 2>/dev/null; kill -KILL "$JOB_PID" 2>/dev/null
  fuser -k -KILL "$WORK/shims/mpiexec" 2>/dev/null
  pkill -KILL -f "$WORK/bin/swarm rank --dir $SW --job $1" 2>/dev/null
  pkill -KILL -f "\-in $EXP/in.lj.long" 2>/dev/null
}
# on_rank0 CMD...: run CMD where rank 0 of the running job lives (here).
on_rank0() { "$@"; }
# insider_attack ARGS...: the equivocate attack, run where the compromised
# coordinators listen (here).
insider_attack() { $ATTACK equivocate "$@"; }
# host_start ID PORT: a long-lived host that may be promoted (E3).
host_start() {
  nohup "$SWARM" host --dir "$SW" --id "host-$1" --listen "127.0.0.1:$2" \
    >"$SW/host-$1.log" 2>&1 &
  echo $! >"$SW/host-$1.pid"
}
host_stop_all() { for f in "$SW"/host-*.pid; do kill -9 "$(cat "$f")" 2>/dev/null || true; done; }

# A site file (e.g. slurm/site-env.sh) replaces any of the functions above to
# spread coordinators, ranks and attackers over the nodes of an allocation.
if [ -n "${SITE_ENV:-}" ]; then
  # shellcheck source=/dev/null
  source "$SITE_ENV"
fi
