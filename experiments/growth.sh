#!/usr/bin/env bash
# E3: a swarm that starts with two coordinators and grows as nodes join.
# Two long-lived hosts join as coordinator candidates; a 16-rank LAMMPS job
# brings the swarm to 18 nodes, which (growth 4:4) warrants four coordinators.
# Once both hosts are promoted, one genesis coordinator is killed: with four
# coordinators the chain must keep going, which it could not have with two.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="${OUT:-$WORK/growth.jsonl}"
N="${N:-16}"
STEPS="${STEPS:-6000}"
make_bin
rm -rf "$SW"; mkdir -p "$SW"
COORDS=2
swarm_init --coordinators 2 --lease-ms 6000 --heartbeat-ms 1000 --growth 4:4
for i in 0 1; do coord_start "$i"; done
for h in a b; do host_start "$h" $((BASE_PORT + 10 + $(printf '%d' "'$h") - 97)); done

roster() { "$SWARM" status --dir "$SW" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["coordinators"]), d["height"])'; }
promoted() { grep -c '"event":"host.promoted"' "$SW"/host-*.log 2>/dev/null | awk -F: '{s+=$2} END {print s+0}'; }

sleep 4
read -r c_before h_before < <(roster)
( cd "$WORK" && env "PATH=$SHIMS:$PATH" $MPI_LAUNCH -n "$N" "$LMP" -in "$EXP/in.lj.long" \
    -var steps "$STEPS" -log none >"$WORK/grow.log" 2>&1; echo $? >"$WORK/grow.rc" ) &
JOB=$!
for _ in $(seq 1 300); do [ "$(promoted)" -ge 2 ] && break; sleep 0.1; done
read -r c_grown h_grown < <(roster)
coord_kill 0
sleep 8
read -r c_after h_after < <(roster)
wait "$JOB"; rc=$(cat "$WORK/grow.rc" 2>/dev/null); rc=${rc:-null}
paused=$(grep -c '"event":"rank.paused"' "$WORK/grow.log" || true)
pass=false
[ "$c_before" = 2 ] && [ "$c_grown" = 4 ] && [ "$h_after" -gt "$h_grown" ] && [ "$rc" = 0 ] \
  && [ "$paused" = 0 ] && pass=true
printf '{"scenario":"E3-growth","pass":%s,"details":{"coordinatorsAtStart":%s,"coordinatorsAfterJob":%s,"promoted":%s,"heightAtKill":%s,"heightAfter8s":%s,"coordinatorsAfterKill":%s,"rc":%s,"paused":%s}}\n' \
  "$pass" "$c_before" "$c_grown" "$(promoted)" "$h_grown" "$h_after" "$c_after" "$rc" "$paused" | tee -a "$OUT"
swarm_down; host_stop_all
