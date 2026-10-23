---- MODULE MC_n4_f1_equivocating ----
\* Four coordinators and one Byzantine that may sign anything (f = 1).
EXTENDS SwarmFinality
CONSTANTS c1, c2, c3, b1, A, B
MCCorr == {c1, c2, c3}
MCFaulty == {b1}
MCValues == {A, B}
MCProposers == <<c1, b1, c2, c3>>
====
