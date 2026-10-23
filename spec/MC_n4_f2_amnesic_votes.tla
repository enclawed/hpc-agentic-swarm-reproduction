---- MODULE MC_n4_f2_amnesic_votes ----
\* The same setting, checking Tendermint's own votes for accountability.
\* Expected to FAIL: TLC's counterexample is the amnesia fork.
EXTENDS SwarmFinality
CONSTANTS c1, c2, b1, b2, A, B
MCCorr == {c1, c2}
MCFaulty == {b1, b2}
MCValues == {A, B}
MCProposers == <<c1, b1, c2, b2>>
====
