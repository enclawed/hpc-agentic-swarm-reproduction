---- MODULE MC_n5_f2_equivocating ----
\* Five coordinators and two Byzantine that may sign anything: beyond the
\* nominal f = 1, but 2Q - N = 3 > 2, so agreement holds.
EXTENDS SwarmFinality
CONSTANTS c1, c2, c3, b1, b2, A, B
MCCorr == {c1, c2, c3}
MCFaulty == {b1, b2}
MCValues == {A, B}
MCProposers == <<c1, b1, c2, b2, c3>>
====
