---- MODULE MC_n3_f1_equivocating ----
\* Three coordinators (unanimous quorum) and one Byzantine that may sign
\* anything: beyond the nominal f = 0, but 2Q - N = 3 > 1, so agreement holds.
EXTENDS SwarmFinality
CONSTANTS c1, c2, b1, A, B
MCCorr == {c1, c2}
MCFaulty == {b1}
MCValues == {A, B}
MCProposers == <<c1, b1, c2>>
====
