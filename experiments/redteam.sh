#!/usr/bin/env bash
# Live red team: LAMMPS on MPI ranks supervised by the swarm, under attack.
# Each scenario starts a fresh swarm, runs a real job, attacks it, and writes
# one JSON line to $OUT with the observed outcome and whether it matches the
# expected (secure) behavior. After every scenario, audit.ts re-verifies the
# coordinators' own ledgers from genesis, and the verdict requires both the
# live observation and the audit to agree. Each scenario's swarm directory is
# kept as $WORK/swarm-<scenario> for inspection.
set -uo pipefail
source "$(dirname "$0")/env.sh"
OUT="${OUT:-$WORK/redteam.jsonl}"
N="${N:-16}"          # ranks per job
STEPS="${STEPS:-6000}" # long enough to attack mid-run (~25 s at 16 ranks)
LEASE_MS="${LEASE_MS:-6000}"
: "${ATTACK:=node --import $REPO/node_modules/tsx/dist/esm/index.mjs $EXP/attacks.ts}"
: "${AUDIT:=node --import $REPO/node_modules/tsx/dist/esm/index.mjs $EXP/audit.ts}"
make_bin
: >"$OUT"

result() { # scenario pass details-json; the loop below adds the audit
  printf '{"scenario":"%s","pass":%s,"details":%s}\n' "$1" "$2" "$3" >"$WORK/last.json"
}

# What the coordinators' own ledgers must show for each scenario.
audit_verdict() { # scenario-function-name
  python3 - "$1" "$WORK/last.json" "$WORK/audit.json" <<'PY2'
import json, sys
name, last, audit = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
ce = {e["who"] for e in audit["coordinatorEvictions"] if e["evidenceVerifies"]}
ne = {e["who"] for e in audit["nodeEvictions"] if e["evidenceVerifies"]}
ok = audit["allVerifyFromGenesis"] and audit["consistent"] and not audit["fork"]
expect = {
  "scenario_device_removed": lambda: ne == {"r3.r5"} and not ce,
  "scenario_equivocation": lambda: ce == {"coord-3"} and not ne,
  "scenario_colluding_finals": lambda: ce == {"coord-2", "coord-3"} and not ne,
  "scenario_withholding_colluders": lambda: not ce and not ne,
}.get(name, lambda: not ce and not ne and not audit["coordinatorEvictions"] and not audit["nodeEvictions"])
auditPass = bool(ok and expect())
last["livePass"] = last.pop("pass")
last["auditPass"] = auditPass
last["pass"] = last["livePass"] and auditPass
last["audit"] = audit
print(json.dumps(last))
PY2
}

# run_job NAME [extra launch flags]: LAMMPS in the background through the shim.
run_job() {
  local name="$1"; shift
  ( cd "$WORK" && SWARM_LAUNCH_FLAGS="--job $name $*" env "PATH=$SHIMS:$PATH" \
      $MPI_LAUNCH -n "$N" "$LMP" -in "$EXP/in.lj.long" -var steps "$STEPS" -log none \
      >"$WORK/$name.log" 2>&1; echo $? >"$WORK/$name.rc" ) &
  JOB_PID=$!
}
# wait_job NAME: sets RC. Must run in this shell (not $(...)): only the parent
# can wait for the job, and the rc file exists only once the job has exited.
wait_job() {
  wait "$JOB_PID" 2>/dev/null
  RC=$(cat "$WORK/$1.rc" 2>/dev/null)
  RC=${RC:-null}
}
wait_leased() { # name count
  for _ in $(seq 1 300); do
    [ "$(grep -c '"event":"rank.leased"' "$WORK/$1.log" 2>/dev/null)" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
height() { local h; h=$(grep -oP '"event":"block".*"height":\K[0-9]+' "$SW/coord-$1.log" 2>/dev/null | tail -1); echo "${h:-0}"; }
count() { grep -c "\"event\":\"$2\"" "$WORK/$1.log" 2>/dev/null || true; }
# ts_of NAME EVENT: wall time (ms) of the first such event, or empty.
ts_of() { grep -m1 "\"event\":\"$2\"" "$WORK/$1.log" 2>/dev/null | grep -oP '"t":\K[0-9]+' || true; }
# delta A B: B - A in ms, or null when either is missing.
delta() { if [ -n "$1" ] && [ -n "$2" ]; then echo $(($2 - $1)); else echo null; fi; }
# %s%N then divide: some date builds ignore the %3N width and print nanoseconds.
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

scenario_baseline() {
  swarm_up "$LEASE_MS" 1000
  run_job base
  wait_leased base "$N"
  wait_job base; local rc=$RC
  local pass=false; [ "$rc" = 0 ] && [ "$(count base rank.paused)" = 0 ] && pass=true
  result R0-baseline "$pass" "{\"rc\":$rc,\"leased\":$(count base rank.leased),\"paused\":$(count base rank.paused)}"
  swarm_down
}

scenario_one_coordinator_down() {
  swarm_up "$LEASE_MS" 1000
  run_job r1
  wait_leased r1 "$N"; sleep 3
  local h0; h0=$(height 0)
  coord_kill 2
  sleep 10
  local h1; h1=$(height 0)
  wait_job r1; local rc=$RC
  local pass=false
  [ "$rc" = 0 ] && [ "$(count r1 rank.paused)" = 0 ] && [ "$h1" -gt "$h0" ] && pass=true
  result R1-coordinator-crash "$pass" "{\"rc\":$rc,\"paused\":$(count r1 rank.paused),\"heightBefore\":$h0,\"heightAfter10s\":$h1}"
  swarm_down
}

scenario_quorum_loss() {
  swarm_up "$LEASE_MS" 1000
  run_job r2
  wait_leased r2 "$N"; sleep 2
  local t_kill; t_kill=$(now_ms)
  coord_kill 1; coord_kill 2
  sleep 14
  local paused; paused=$(count r2 rank.paused)
  local t_restart; t_restart=$(now_ms)
  coord_start 1; coord_start 2
  wait_job r2; local rc=$RC
  local resumed; resumed=$(count r2 rank.resumed)
  local t_pause; t_pause=$(ts_of r2 rank.paused)
  local t_resume; t_resume=$(ts_of r2 rank.resumed)
  local pass=false
  [ "$rc" = 0 ] && [ "$paused" = "$N" ] && [ "$resumed" = "$N" ] && pass=true
  result R2-quorum-loss "$pass" "{\"rc\":$rc,\"paused\":$paused,\"resumed\":$resumed,\"killToFirstPauseMs\":$(delta "$t_kill" "$t_pause"),\"restartToFirstResumeMs\":$(delta "$t_restart" "$t_resume")}"
  swarm_down
}

scenario_device_removed() {
  swarm_up "$LEASE_MS" 1000
  mkdir -p "$WORK/dev"
  for ((r = 0; r < N; r++)); do touch "$WORK/dev/rank-$r"; done
  run_job r3 --device-file "$WORK/dev/rank-{rank}"
  wait_leased r3 "$N"; sleep 3
  local t_rm; t_rm=$(now_ms)
  rm -f "$WORK/dev/rank-5"
  wait_job r3; local rc=$RC
  local t_kill; t_kill=$(ts_of r3 rank.killed)
  sleep 3
  local evicted; evicted=$("$SWARM" status --dir "$SW" 2>/dev/null | grep -c "\"r3.r5\"" || true)
  local pass=false
  [ "$rc" != 0 ] && [ "$(count r3 rank.killed)" -ge 1 ] && [ "$evicted" -ge 1 ] && pass=true
  result R3-device-removed "$pass" "{\"rc\":$rc,\"killed\":$(count r3 rank.killed),\"removalToKillMs\":$(delta "$t_rm" "$t_kill"),\"evictedOnChain\":$([ "$evicted" -ge 1 ] && echo true || echo false)}"
  swarm_down
}

scenario_forged_dirty() {
  swarm_up "$LEASE_MS" 1000
  run_job r4
  wait_leased r4 "$N"; sleep 2
  local out; out=$($ATTACK forge-dirty --dir "$SW" --victim r4.r3)
  wait_job r4; local rc=$RC
  local pass=false
  echo "$out" | grep -q '"evicted":false' && echo "$out" | grep -q '"stillMember":true' && [ "$rc" = 0 ] && pass=true
  result R4-forged-dirty-heartbeat "$pass" "{\"rc\":$rc,\"attack\":$out}"
  swarm_down
}

scenario_replay() {
  swarm_up "$LEASE_MS" 1000
  run_job r5
  wait_job r5; local rc=$RC
  local out; out=$($ATTACK replay --dir "$SW")
  local pass=false
  echo "$out" | grep -q '"leasesRenewedDuringReplay":0' && pass=true
  result R5-heartbeat-replay "$pass" "{\"rc\":$rc,\"attack\":$out}"
  swarm_down
}

scenario_equivocation() {
  swarm_up "$LEASE_MS" 1000
  run_job r6
  wait_leased r6 "$N"; sleep 2
  coord_kill 3
  local out; out=$(insider_attack --dir "$SW" --index 3)
  wait_job r6; local rc=$RC
  local pass=false
  echo "$out" | grep -q '"evicted":true' && echo "$out" | grep -q '"halted":null' && [ "$rc" = 0 ] && pass=true
  result R6-byzantine-coordinator "$pass" "{\"rc\":$rc,\"attack\":$out}"
  swarm_down
}

scenario_spoof() {
  swarm_up "$LEASE_MS" 1000
  run_job r7
  wait_leased r7 "$N"; sleep 2
  local out; out=$($ATTACK spoof-coordinator --dir "$SW" --as coord-1)
  wait_job r7; local rc=$RC
  local pass=false
  echo "$out" | grep -q '"acceptedForgedBlock":false' && echo "$out" | grep -q '"coord-2"' && [ "$rc" = 0 ] && pass=true
  result R7-spoofed-coordinator "$pass" "{\"rc\":$rc,\"attack\":$out}"
  swarm_down
}

scenario_colluding_finals() {
  # Two of four coordinators, with their real keys, sign a conflicting final at
  # every height: more Byzantine coordinators than four can tolerate. There must
  # be no fork (no conflicting block can gather a quorum of finals without an
  # honest coordinator), both must be evicted on their own signatures, and the
  # two honest coordinators must carry on as a unanimous pair.
  swarm_up "$LEASE_MS" 1000
  run_job r10
  wait_leased r10 "$N"; sleep 2
  coord_kill 2; coord_kill 3
  local out; out=$(insider_attack --dir "$SW" --index 2,3 --kind final)
  wait_job r10; local rc=$RC
  local pass=false
  echo "$out" | grep -q '"evicted":true' && echo "$out" | grep -q '"fork":false' \
    && echo "$out" | grep -q '"halted":null' \
    && echo "$out" | grep -q '"coordinatorsAfter":\["coord-0","coord-1"\]' && [ "$rc" = 0 ] && pass=true
  result R10-colluding-finals "$pass" "{\"rc\":$rc,\"attack\":$out}"
  swarm_down
}

scenario_withholding_colluders() {
  # Two of four coordinators, with their real keys, refuse to vote for anything
  # honest and sign finals only for a block of their own. That leaves two
  # honest coordinators, short of the quorum of three: safety must hold (no
  # fork, no forged commit), the chain must stop, and every rank must be paused
  # within one lease, because nothing can renew it. Liveness is what is lost.
  swarm_up "$LEASE_MS" 1000
  run_job r11
  wait_leased r11 "$N"; sleep 2
  coord_kill 2; coord_kill 3
  local out; out=$(insider_attack --dir "$SW" --index 2,3 --kind final --withhold true)
  local paused; paused=$(count r11 rank.paused)
  # The job cannot finish while the swarm is stopped; end it.
  job_kill_all r11
  wait "$JOB_PID" 2>/dev/null
  local pass=false
  echo "$out" | grep -q '"fork":false' && echo "$out" | grep -q '"blocksAfterAttack":0' \
    && [ "$paused" = "$N" ] && pass=true
  result R11-withholding-colluders "$pass" "{\"paused\":$paused,\"attack\":$out}"
  swarm_down
}

scenario_tampered_ledger() {
  swarm_up "$LEASE_MS" 1000
  sleep 8
  coord_kill 0
  local f="$SW/data/ledger-coord-0.jsonl"
  local before; before=$(wc -l <"$f")
  # Rewrite the time in block 3 on disk, as an attacker with file access would.
  python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
lines = open(p).read().splitlines()
b = json.loads(lines[2]); b["block"]["header"]["time"] += 1
lines[2] = json.dumps(b)
open(p, "w").write("\n".join(lines) + "\n")
PY
  coord_start 0
  sleep 6
  local trunc; trunc=$(grep '"event":"coordinator.up"' "$SW/coord-0.log" | tail -1 | grep -oP '"truncatedAt":\K[0-9a-z]+')
  local h0 h1; h0=$(height 0); h1=$(height 1)
  local pass=false
  [ "$trunc" = 3 ] && [ $((h1 - h0)) -le 1 ] && [ $((h0 - h1)) -le 1 ] && pass=true
  result R8-tampered-ledger "$pass" "{\"storedBlocks\":$before,\"truncatedAt\":\"$trunc\",\"heightCoord0\":$h0,\"heightCoord1\":$h1}"
  swarm_down
}

scenario_socket_token() {
  swarm_up "$LEASE_MS" 1000
  run_job r9
  wait_leased r9 "$N"
  local sock; sock="${XDG_RUNTIME_DIR:-/tmp}/enclawed-$(id -u)/r9.r0.sock"
  local out; out=$(on_rank0 $ATTACK socket-token --dir "$SW" --socket "$sock")
  local mode; mode=$(on_rank0 stat -c %a "$sock" 2>/dev/null || echo "?")
  wait_job r9; local rc=$RC
  local pass=false
  echo "$out" | grep -q '"code":"unauthorized"' && [ "$mode" = 600 ] && pass=true
  result R9-decision-socket "$pass" "{\"rc\":$rc,\"socketMode\":\"$mode\",\"attack\":$out}"
  swarm_down
}

for s in ${SCENARIOS:-baseline one_coordinator_down quorum_loss device_removed forged_dirty replay equivocation spoof tampered_ledger socket_token colluding_finals withholding_colluders}; do
  "scenario_$s"
  $AUDIT "$SW" >"$WORK/audit.json" 2>"$WORK/audit-$s.err"
  audit_verdict "scenario_$s" | tee -a "$OUT"
  rm -rf "$WORK/swarm-$s"; mv "$SW" "$WORK/swarm-$s"
  sleep 1
done
