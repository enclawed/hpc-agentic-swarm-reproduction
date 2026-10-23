# HPC agentic swarm: reproduction data

The data and scripts behind the results of *A Deterministic Security Runtime for
LLM Agents on MPI and Batch-Scheduled HPC Systems: Consensus-Governed,
Hardware-Rooted Supervision of Every Rank* (Alfredo Metere, Enclawed, Inc.,
2026, [doi:10.5281/zenodo.23602948](https://doi.org/10.5281/zenodo.23602948)),
for every result that runs on the open-source
[enclawed-oss](https://github.com/enclawed/enclawed-oss) alone.

**[RESULTS.md](RESULTS.md) is the one page to read:** every test, what a pass
means, what happened, and how the result compares with the 23 systems the
paper surveys.

## At a glance

| | |
|---|---|
| Tests | **23 of 23 passed**: the 12 HASB attacks (R0–R11), growth from two coordinators, three agent scenarios and the gate check on a real model, and six model-checking runs |
| Launch gate vs. a real model | **24 of 24** planted launches denied; **108 of 108** legitimate launches allowed |
| A coordinator that misbehaves | evicted on its own signatures (R6), even two of four colluding (R10) |
| A tampered or removed Enclaweder | its rank killed in **54 ms**; an agent's LAMMPS job dead **58 ms** after its Enclaweder was removed |
| Quorum lost | every rank and every agent paused; no fork and no false commit in any run |
| Cost | **none measurable** on the compute loop of 16-rank LAMMPS, CPU or GPU; about 3 s of start-up per job |

## What is here

| Path | What |
|---|---|
| `RESULTS.md` | the graded results, the HASB catalogue and the comparison |
| `results/paper/` | the runs the paper reports, as recorded |
| `results/rerun/` | the same experiments re-run on enclawed-oss alone, graded the same way (being added) |
| `experiments/` | the experiment scripts (E1, E2, E3, E6) and the LAMMPS inputs |
| `experiments/attacks.ts` | the attack tools of the red team |
| `experiments/audit.ts` | the independent ledger audit every red-team verdict needs |
| `experiments/agents/` | the agent swarm: harness, task prompt, planted notes, model log, analysis |
| `spec/` | the TLA+ model of the finality step |
| `enclawed-oss/` | submodule: [enclawed-oss](https://github.com/enclawed/enclawed-oss) pinned to the public snapshot the experiments run against |
| `scripts/` | `setup.sh`, `run.sh`, `tlc.sh`, `summarize.py` |

## HASB, the HPC Agent Security Benchmark

The red team of the paper is published here as a benchmark: twelve attacks on
a supervised MPI job (R0–R11), three on agents driven by a real model
(A1–A3), and the gate check, each with the outcome a secure system must
produce written down before it runs. `RESULTS.md` lists them. The harness drives
enclawed-oss; another system is measured by running the same scenarios
against it and grading the outcome with the same criteria. We welcome results
from other systems and will list them.

## Reproduce

Requirements, with the versions the paper used:

- Linux, 16 physical cores (the paper: AMD Ryzen 9 9950X3D2, 62 GB, Linux 6.18)
- Node 22 (22.22.1) and pnpm 10 (10.32.1); Python 3 (3.14)
- LAMMPS built with MPI (stable, 30 Sep 2026); `LMP` points at the `lmp` binary.
  E1 runs every measurement on the CPU and again with the GPU package, which
  needs LAMMPS built with it (the paper: CUDA, single precision) and a GPU;
  `ACCELS=cpu` runs the CPU half alone
- MPICH with Hydra (5.0.2); `MPI_BIN` is the directory holding its `mpiexec`
- for the model checking: Java (25) and `tla2tools.jar` with TLC 2.19; `TLA2TOOLS` points at it
- for E6: [Ollama](https://ollama.com) with `gemma4:latest` and a GPU that
  holds it at 16 parallel requests (the paper: one 96 GB GPU)

```sh
git clone --recurse-submodules https://github.com/enclawed/hpc-agentic-swarm-reproduction.git
cd hpc-agentic-swarm-reproduction
scripts/setup.sh              # builds the enclawed-oss submodule
LMP=/path/to/lmp MPI_BIN=/path/to/mpich/bin TLA2TOOLS=/path/to/tla2tools.jar \
  scripts/run.sh              # all experiments; or name some: tlc e1 e2 e3 e6
python3 scripts/summarize.py results/rerun
```

`summarize.py` prints one row per test with **PASS** or **FAIL** and exits
non-zero if any test failed. Running all of it takes about an hour and a half,
most of it E6.

## What is simulated

- **The Enclaweder.** The paper's E1 and red team ran with every key held by a
  real Enclaweder, the hardware root of trust. Where one rank loses its own
  Enclaweder while the others keep theirs (R3, A3), a file per rank stands in
  for it: present means CLEAN, removed means DIRTY for good. On a host without
  an Enclaweder the scripts run on software keys, with a file for every rank;
  the runtime code is the same one that drives a real Enclaweder.
- **The cluster.** One host: coordinators, ranks and attackers talk over
  loopback. The paper's scaling across nodes is not part of these results.
- **The agents' instructions.** The task prompts and the planted instructions
  are scripted; every decision the agents take is the model's own, and
  `model.jsonl` in each agent run records every request and reply.

## Not included

Three experiments of the paper, E4 (a cluster reached over SSH alone,
operated through the monitor), E5 (tampering with the monitor in a real
browser) and E7 (removing the Enclaweder under a running swarm, watched from
the monitor), exercise the operator's monitor, which is proprietary. They are
not in this repository. We welcome inquiries about them at
alfredo.metere@enclawed.com.

`scripts/count.sh` reproduces the open-source share of the runtime that the
paper's Implementation section counts: lines of code and of tests, and test
cases.

## License

MIT, see [LICENSE](LICENSE).

## Citing

Alfredo Metere. *A Deterministic Security Runtime for LLM Agents on MPI and
Batch-Scheduled HPC Systems: Consensus-Governed, Hardware-Rooted Supervision of
Every Rank.* Enclawed, Inc., 2026. doi:10.5281/zenodo.23602948
