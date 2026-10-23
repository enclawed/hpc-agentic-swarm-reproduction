// Live red-team attacks against a running swarm (see redteam.sh).
//
//   node --import tsx attacks.ts <attack> --dir SWARM_DIR [--victim ID] [--index N]
//
// Every attack prints one JSON line with what it tried and what the chain
// shows afterwards, so redteam.sh can assert the outcome.

import { readFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { blockHash, SwarmLedger, statementDigest } from "../enclawed-oss/src/enclawed/swarm/chain.js";
import { parseHostPorts, runCoordinator } from "../enclawed-oss/src/enclawed/swarm/daemon.js";
import { signHeartbeat } from "../enclawed-oss/src/enclawed/swarm/heartbeat.js";
import { SwarmHub, type Envelope } from "../enclawed-oss/src/enclawed/swarm/net.js";
import { softwareSigner, type SwarmSigner } from "../enclawed-oss/src/enclawed/swarm/signer.js";
import type { Genesis, Statement, SwarmTx } from "../enclawed-oss/src/enclawed/swarm/types.js";

const argv = process.argv.slice(2);
const attack = argv[0];
const flag = (name: string, fallback?: string): string => {
  const i = argv.indexOf(`--${name}`);
  const v = i >= 0 ? argv[i + 1] : fallback;
  if (v === undefined) {
    throw new Error(`--${name} is required`);
  }
  return v;
};
const dir = flag("dir");
const genesis = JSON.parse(readFileSync(path.join(dir, "genesis.json"), "utf8")) as Genesis;
const coords = parseHostPorts(readFileSync(path.join(dir, "coordinators.txt"), "utf8").trim());
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const report = (fields: Record<string, unknown>) =>
  process.stdout.write(JSON.stringify({ attack, ...fields }) + "\n");

/** Follows the chain like any monitor; every block it accepts has a verified QC. */
async function observer(): Promise<{ ledger: SwarmLedger; hub: SwarmHub }> {
  const { ledger } = SwarmLedger.restore(genesis);
  const hub = new SwarmHub({
    id: `observer-${process.pid}`,
    role: "monitor",
    connect: coords,
    ledger,
    onCommit: (cb) => {
      const r = ledger.commit(cb);
      if (!r.ok && r.code === "gap") {
        hub.requestSync(ledger.height + 1);
      }
    },
  });
  await hub.start();
  // Catch up to the tip.
  let last = -1;
  for (let i = 0; i < 100 && ledger.height !== last; i++) {
    last = ledger.height;
    await sleep(300);
  }
  return { ledger, hub };
}

/** Raw connections that claim whatever role the attacker likes. */
function rawSend(role: "coordinator" | "node", id: string, envs: Envelope[]): Promise<void> {
  return Promise.all(
    coords.map(
      (c) =>
        new Promise<void>((resolve) => {
          const s = net.connect(c.port, c.host, () => {
            s.write(JSON.stringify({ kind: "hello", from: id, role }) + "\n");
            for (const e of envs) {
              s.write(JSON.stringify(e) + "\n");
            }
            setTimeout(() => {
              s.destroy();
              resolve();
            }, 300);
          });
          s.on("error", () => resolve());
        }),
    ),
  ).then(() => undefined);
}

async function forgeDirty(): Promise<void> {
  // An outsider tries to get a healthy node evicted by forging its DIRTY heartbeat.
  const victim = flag("victim");
  const { ledger, hub } = await observer();
  const attacker = softwareSigner(victim); // right id, wrong key
  const hb = await signHeartbeat(attacker, {
    swarmId: genesis.swarmId,
    nodeId: victim,
    epoch: ledger.state.epoch,
    seq: 1_000_000,
    time: Date.now(),
    status: "DIRTY",
    reason: "forged",
  });
  const evictTx: SwarmTx = { type: "node.evict", nodeId: victim, reason: "dirty", evidence: hb };
  await rawSend("node", victim, [
    { kind: "heartbeat", hb },
    { kind: "tx", tx: evictTx },
  ]);
  await sleep(4000);
  report({
    victim,
    victimWasMember: true,
    evicted: ledger.state.evicted.has(victim),
    stillMember: ledger.state.nodes.has(victim),
    height: ledger.height,
  });
  await hub.close();
}

async function replayHeartbeats(): Promise<void> {
  // Every heartbeat that bought a lease is public on chain. Replay them all to
  // keep leases alive for nodes that have stopped sending.
  const { ledger, hub } = await observer();
  const used = ledger
    .blocksFrom(1, 100_000)
    .flatMap((b) => b.block.txs)
    .filter((t): t is Extract<SwarmTx, { type: "lease.grant" }> => t.type === "lease.grant")
    .map((t) => t.heartbeat);
  const before = new Map([...ledger.state.leases].map(([k, v]) => [k, v.height]));
  await rawSend(
    "node",
    "replayer",
    used.map((hb) => ({ kind: "heartbeat" as const, hb })),
  );
  await sleep(4000);
  const renewed = [...ledger.state.leases].filter(([k, v]) => before.get(k) !== v.height).length;
  // Leases can only be renewed by fresh heartbeats; count any renewal of a
  // node whose heartbeats we replayed and that is not itself running.
  report({ replayed: used.length, leasesRenewedDuringReplay: renewed, height: ledger.height });
  await hub.close();
}

async function spoofCoordinator(): Promise<void> {
  // An outsider with a coordinator's name but not its key tries to inject a
  // block: a proposal, a full set of forged precommits, and a forged commit.
  const target = flag("as", "coord-1");
  const { ledger, hub } = await observer();
  const h = ledger.height + 1;
  const headBefore = ledger.state.headHash;
  const fakes: SwarmSigner[] = genesis.coordinators.map((c) => softwareSigner(c.id));
  const block = {
    header: {
      swarmId: genesis.swarmId,
      height: h,
      round: 0,
      prevHash: ledger.state.headHash,
      proposer: target,
      epoch: ledger.state.epoch,
      time: Date.now(),
      txRoot: "0".repeat(64),
      active: [],
    },
    txs: [],
  };
  const hash = blockHash(block.header);
  const sign = async (s: SwarmSigner, kind: Statement["kind"]): Promise<Statement> => {
    const st: Statement = {
      swarmId: genesis.swarmId,
      kind,
      height: h,
      round: 0,
      blockHash: hash,
      ...(kind === "proposal" ? { validRound: -1 } : {}),
      signer: s.key.id,
      sig: "",
    };
    st.sig = await s.sign(statementDigest(st));
    return st;
  };
  const votes = await Promise.all(fakes.map((s) => sign(s, "precommit")));
  const finals = await Promise.all(fakes.map((s) => sign(s, "final")));
  const proposal = await sign(fakes[1], "proposal");
  // Also try to frame an honest coordinator with fabricated double-sign evidence.
  const framed: SwarmTx = {
    type: "coordinator.evict",
    coordinatorId: "coord-2",
    evidence: {
      a: { ...votes[2], blockHash: "a".repeat(64) },
      b: { ...votes[2], blockHash: "b".repeat(64) },
    },
  };
  await rawSend("coordinator", target, [
    { kind: "consensus", msg: { type: "proposal", statement: proposal, block } },
    ...[...votes, ...finals].map((statement) => ({
      kind: "consensus" as const,
      msg: { type: "vote" as const, statement },
    })),
    {
      kind: "commit",
      committed: { block, hash, qc: { height: h, round: 0, blockHash: hash, votes: finals } },
    },
    { kind: "tx", tx: framed },
  ]);
  await sleep(4000);
  report({
    injectedHash: hash,
    acceptedForgedBlock: ledger.blocksFrom(1, 100_000).some((b) => b.hash === hash),
    chainAdvancedHonestly: ledger.height >= h && ledger.block(h)?.hash !== hash,
    headChanged: ledger.state.headHash !== headBefore,
    coordinators: ledger.state.coordinators.map((c) => c.id),
    halted: ledger.state.halted,
  });
  await hub.close();
}

async function equivocate(): Promise<void> {
  // Insider attack: the hosts of coordinators --index (e.g. "3" or "2,3") are
  // compromised, with their real keys. Each runs the protocol but also signs a
  // conflicting statement of --kind (prevote or final) for every one it sends.
  // Two colluders out of four exceed what 4 coordinators tolerate (f = 1).
  const kind = flag("kind", "prevote") as Statement["kind"];
  // --withhold true: send nothing honest at all, only a final for a block of
  // their own at each height (R11). Two such colluders out of four leave the
  // honest pair short of a quorum.
  const withhold = flag("withhold", "false") === "true";
  const fakeFinalAt = new Set<number>();
  const indices = flag("index", "3").split(",").map(Number);
  const ids = indices.map((i) => `coord-${i}`);
  let doubleSigned = 0;
  const handles = await Promise.all(
    indices.map(async (index) => {
      const id = `coord-${index}`;
      const signer = softwareSigner(id, readFileSync(path.join(dir, "keys", `${id}.pem`), "utf8"));
      const handle = await runCoordinator({
        genesis,
        signer,
        dataDir: path.join(dir, `data-byzantine-${index}`),
        listen: coords[index],
        peers: coords.filter((_, i) => i !== index),
      });
      const honest = handle.hub.broadcastConsensus.bind(handle.hub);
      handle.hub.broadcastConsensus = (msg) => {
        if (withhold) {
          if (msg.type === "vote" && !fakeFinalAt.has(msg.statement.height * 10 + index)) {
            fakeFinalAt.add(msg.statement.height * 10 + index);
            const fake: Statement = {
              ...msg.statement,
              kind: "final",
              round: 0,
              blockHash: "f".repeat(64),
              sig: "",
            };
            void signer.sign(statementDigest(fake)).then((sig) => {
              doubleSigned += 1;
              honest({ type: "vote", statement: { ...fake, sig } });
            });
          }
          return;
        }
        honest(msg);
        if (msg.type === "vote" && msg.statement.kind === kind) {
          const st = msg.statement;
          const other = kind === "final" ? "f".repeat(64) : st.blockHash ? null : "e".repeat(64);
          const evil: Statement = { ...st, blockHash: other, sig: "" };
          void signer.sign(statementDigest(evil)).then((sig) => {
            doubleSigned += 1;
            honest({ type: "vote", statement: { ...evil, sig } });
          });
        }
      };
      return handle;
    }),
  );
  const { ledger, hub } = await observer();
  if (withhold) {
    const h0 = ledger.height;
    await sleep(2 * genesis.params.leaseMs);
    report({
      byzantine: ids,
      withhold: true,
      fakeFinalsSigned: doubleSigned,
      heightAtAttack: h0,
      blocksAfterAttack: ledger.height - h0,
      fork: ledger.forkEvidence !== null,
      coordinatorsAfter: ledger.state.coordinators.map((c) => c.id),
      halted: ledger.state.halted,
    });
    await Promise.all(handles.map((h) => h.stop()));
    await hub.close();
    return;
  }
  const allEvicted = () => ids.every((id) => ledger.state.evicted.has(id));
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline && !allEvicted() && !ledger.state.halted) {
    await sleep(200);
  }
  const evictedAt = allEvicted() ? ledger.height : null;
  await Promise.all(handles.map((h) => h.stop()));
  // The honest remainder keeps producing blocks.
  const h0 = ledger.height;
  await sleep(5000);
  report({
    byzantine: ids,
    kind,
    doubleSigned,
    evicted: evictedAt !== null,
    evictedAtHeight: evictedAt,
    coordinatorsAfter: ledger.state.coordinators.map((c) => c.id),
    blocksAfterEviction: ledger.height - h0,
    fork: ledger.forkEvidence !== null,
    halted: ledger.state.halted,
  });
  await hub.close();
}

async function socketToken(): Promise<void> {
  // A process that can reach a rank's decision socket but lacks its token.
  const sock = flag("socket");
  const reply: string = await new Promise((resolve) => {
    const s = net.connect(sock, () => {
      s.write(
        JSON.stringify({ token: "guess", action: "write-results", class: "irreversible" }) + "\n",
      );
    });
    s.setEncoding("utf8");
    s.on("data", (d: string) => {
      s.destroy();
      resolve(d.trim());
    });
    s.on("error", (e) => resolve(JSON.stringify({ error: e.message })));
  });
  report({ socket: sock, reply: JSON.parse(reply) as unknown });
}

const attacks: Record<string, () => Promise<void>> = {
  "forge-dirty": forgeDirty,
  replay: replayHeartbeats,
  "spoof-coordinator": spoofCoordinator,
  equivocate,
  "socket-token": socketToken,
};
const run = attacks[attack];
if (!run) {
  process.stderr.write(`unknown attack ${attack}; one of ${Object.keys(attacks).join(", ")}\n`);
  process.exit(2);
}
run().then(
  () => process.exit(0),
  (err: unknown) => {
    process.stderr.write(String(err instanceof Error ? err.stack : err) + "\n");
    process.exit(1);
  },
);
