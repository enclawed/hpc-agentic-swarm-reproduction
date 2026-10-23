# Results

**Every test passed: 23 of 23** in the runs the paper reports, graded below.
The model checking, re-run on enclawed-oss alone, reproduces the paper's
state counts exactly (`results/rerun/tlc`); the other re-runs are added to
`results/rerun` as they complete.

How to read this page: each test names an attack, and the column *PASS
means* states, before the run, what a secure system must do. **PASS** means
Enclawed did exactly that; **FAIL** means it did not. A red-team test passes
only if the live run *and* an independent re-verification of all four
coordinators' ledgers agree.

## The five numbers that matter

1. **24 of 24** launches ordered by injected or hijacked instructions were
   denied by the launch gate, on a real model (Gemma 4), with **0** of 108
   legitimate launches denied.
2. **54 ms** from an Enclaweder's removal to its rank's death; **58 ms** to the
   death of an agent's own LAMMPS job.
3. **0 forks** in any run, including two of four coordinators colluding with
   their genuine keys, beyond the fault threshold (R10, R11).
4. **0 model requests** started by any agent while the swarm had lost its
   quorum: every agent and its job paused, and every one resumed.
5. **No measurable cost** on the compute loop of a 16-rank LAMMPS job, on the CPU
   or with the GPU package, every rank on the Enclaweder's key; start-up adds about
   3 s per job.

## How Enclawed compares

The paper surveys 23 systems that let LLM agents use HPC or that gate agents
deterministically (section 4.1, verified against primary sources on
2026-10-21). Five capabilities decide whether a system can even attempt the
tests on this page:

- **C1** agents launch work on HPC or MPI
- **C2** a deterministic launch gate
- **C3** a Byzantine-fault-tolerant chain governing the runtime
- **C4** hardware-held node keys whose removal or tampering acts on the runtime
- **C5** supervision of every running rank

| Kind of system | Surveyed examples | C1 | C2 | C3 | C4 | C5 | Tests below it has a mechanism for |
|---|---|---|---|---|---|---|---|
| Agent frameworks with the operator's scheduler access | Academy, URSA, LAMMPS-Agents, flux-mcp, hpc-mcp, LLNL descriptive execution, RCAC MCP, MDCrow, ChemGraph, El Agente, Parsl + LangChain, VibeCodeHPC | yes or partial | no (URSA unclear) | no | no | no | **none** |
| Submission gates | Diamond Agent, LARA-HPC, dtu-hpc-mcp, Globus Compute, Flux job policy, ORNL S3M | yes or partial | partial (dtu-hpc-mcp: yes, one site) | no | no | no | the gate check only; nothing after submission |
| General agent policy engines | Microsoft Agent Governance Toolkit, Keycard + Smallstep | no | generic or per call | no | partial (Keycard signs requests; no heartbeat or eviction) | no | the gate check, without HPC launch parsing |
| Fault-tolerant ledgers, not for agents | TrustMesh, BAASH | no | no | yes or partial | no | no | none of the tests: they govern scheduling or storage, not running ranks |
| **Enclawed** | | **yes** | **yes** | **yes** | **yes** | **yes** | **all 23, and passed all 23** |

The column *Needs* in the tables below names the capabilities each test
requires. No surveyed system other than Enclawed has C5, so none has a
mechanism for any test that needs it: R2, R3, R9, R11, A1, A2, A3. This
comparison is derived from each system's published capabilities; HASB has
not been run against them, and we invite their authors to run it.

## HASB: the HPC Agent Security Benchmark

The tests in the E2 and E6 tables are the benchmark. Each is defined by its
attack and its *PASS means* column, independently of how a system implements
it; `experiments/redteam.sh` and `experiments/agents/agents.sh` are the
harness for enclawed-oss.

