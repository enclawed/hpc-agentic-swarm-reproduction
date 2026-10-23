// Independent audit of a red-team scenario, from the coordinators' own disks.
//
//   node --import tsx audit.ts SWARM_DIR
//
// Re-verifies every stored ledger from genesis with the production validation
// code (each block's quorum certificate, parent hash, transactions), and
// reports what the chain actually recorded: height, fork, the coordinator set,
// evictions with their evidence re-checked, and whether all ledgers agree.
// This does not trust the attack tools' own reports.

import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  fileLedgerStore,
  SwarmLedger,
  verifyEquivocation,
} from "../enclawed-oss/src/enclawed/swarm/chain.js";
import { verifyHeartbeat } from "../enclawed-oss/src/enclawed/swarm/heartbeat.js";
import type { SwarmPrincipalKey } from "../enclawed-oss/src/enclawed/swarm/signer.js";
import type { Genesis } from "../enclawed-oss/src/enclawed/swarm/types.js";

const dir = process.argv[2];
const genesis = JSON.parse(readFileSync(path.join(dir, "genesis.json"), "utf8")) as Genesis;
const files = readdirSync(path.join(dir, "data"))
  .filter((f) => /^ledger-.*\.jsonl$/.test(f))
  .toSorted();

const ledgers = files.map((f) => {
  const raw = fileLedgerStore(path.join(dir, "data", f)).load();
  const { ledger, truncatedAt } = SwarmLedger.restore(genesis, {
    load: () => raw,
    append() {},
    rewrite() {},
  });
  return { id: f.slice("ledger-".length, -".jsonl".length), raw, ledger, truncatedAt };
});

// The longest verified chain is the reference; every other must be a prefix of it.
const ref = ledgers.toSorted((a, b) => b.ledger.height - a.ledger.height)[0];
const consistent = ledgers.every(({ ledger }) => {
  for (let h = 1; h <= ledger.height; h++) {
    if (ledger.block(h)?.hash !== ref.ledger.block(h)?.hash) {
      return false;
    }
  }
  return true;
});

const coordinatorEvictions: unknown[] = [];
const nodeEvictions: unknown[] = [];
const rosters = { swarmId: genesis.swarmId, coordinators: genesis.coordinators };
const refHeight = ref?.ledger.height ?? 0;
// Each node's key, from its join on chain. The ledger keeps only recent
// states, so on a long chain the state before an eviction may be gone.
const joined = new Map<string, SwarmPrincipalKey>();
for (let h = 1; h <= refHeight; h++) {
  const cb = ref.ledger.block(h)!;
  for (const tx of cb.block.txs) {
    if (tx.type === "node.join") {
      joined.set(tx.node.id, tx.node);
    } else if (tx.type === "coordinator.evict") {
      coordinatorEvictions.push({
        height: h,
        who: tx.coordinatorId,
        kind: tx.evidence.a.kind,
        evidenceVerifies: verifyEquivocation(rosters, tx.evidence),
      });
    } else if (tx.type === "node.evict") {
      const key = joined.get(tx.nodeId);
      nodeEvictions.push({
        height: h,
        who: tx.nodeId,
        reason: tx.reason,
        evidenceVerifies:
          tx.reason === "dirty" && key
            ? verifyHeartbeat(key, tx.evidence) && tx.evidence.body.status === "DIRTY"
            : null,
      });
    }
  }
}

process.stdout.write(
  JSON.stringify({
    ledgers: ledgers.map((l) => ({
      id: l.id,
      stored: l.raw.length,
      verified: l.ledger.height,
      truncatedAt: l.truncatedAt,
    })),
    allVerifyFromGenesis: ledgers.every((l) => l.truncatedAt === null),
    consistent,
    fork: ledgers.some((l) => l.ledger.forkEvidence !== null),
    height: ref?.ledger.height ?? 0,
    halted: ref?.ledger.state.halted ?? null,
    coordinators: ref?.ledger.state.coordinators.map((c) => c.id) ?? [],
    coordinatorEvictions,
    nodeEvictions,
  }) + "\n",
);
