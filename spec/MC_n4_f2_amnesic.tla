---- MODULE MC_n4_f2_amnesic ----
\* Four coordinators and two amnesic Byzantine ones: more than f = 1, so a
\* fork is reachable. The finals must still name the culprits.
EXTENDS SwarmFinality
CONSTANTS c1, c2, b1, b2, A, B
MCCorr == {c1, c2}
MCFaulty == {b1, b2}
MCValues == {A, B}
MCProposers == <<c1, b1, c2, b2>>
====
