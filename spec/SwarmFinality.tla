---------------------------- MODULE SwarmFinality ----------------------------
(***************************************************************************)
(* One height of the swarm chain's consensus: Tendermint's propose /       *)
(* prevote / precommit rules with locking, followed by the swarm's final   *)
(* step (a decided coordinator signs one round-free "final" for the        *)
(* height; a block commits on a quorum of finals).                         *)
(*                                                                         *)
(* Faulty coordinators come in two strengths:                              *)
(*   Equivocate = TRUE   they may sign anything, including two votes for   *)
(*                       one (kind, round) slot;                           *)
(*   Equivocate = FALSE  "amnesic": at most one vote per slot, but they    *)
(*                       ignore their locks across rounds.                 *)
(* Either kind may sign finals for several values.                         *)
(*                                                                         *)
(* Rounds are entered at any time (an over-approximation of timeouts), so  *)
(* the safety properties below hold whatever the network timing.           *)
(*                                                                         *)
(* Faulty messages are fixed in Init, as in Informal Systems' Tendermint   *)
(* accountability spec: every message a faulty coordinator could ever     *)
(* send (Equivocate) or one chosen message per slot (amnesic). Correct     *)
(* rules fire on "there exists a quorum", so any adaptive attacker's       *)
(* messages are one of the enumerated sets, delivered whenever.            *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS Corr, Faulty, Values, MaxRound, Equivocate, ProposerSeq, None, Nil

Procs  == Corr \cup Faulty
N      == Cardinality(Procs)
F      == (N - 1) \div 3
Q      == N - F                     \* quorum, as quorumSize() in chain.ts
Rounds == 0..MaxRound
VRs    == -1..(MaxRound - 1)
ValOrNil == Values \cup {Nil}

Proposer(r) == ProposerSeq[(r % Len(ProposerSeq)) + 1]

VARIABLES round, step, decision, lockedValue, lockedRound, validValue,
          validRound, propose, prevote, precommit, final, committed

vars == <<round, step, decision, lockedValue, lockedRound, validValue,
          validRound, propose, prevote, precommit, final, committed>>
state == <<round, step, decision, lockedValue, lockedRound, validValue,
           validRound, committed>>

Senders(S) == {m.src : m \in S}
PV(r, v) == {m \in prevote : m.r = r /\ m.v = v}
PC(r, v) == {m \in precommit : m.r = r /\ m.v = v}
QPV(r, v) == Cardinality(Senders(PV(r, v))) >= Q
AnyQPV(r) == Cardinality(Senders({m \in prevote : m.r = r})) >= Q
FinalSenders(v) == {m.src : m \in {x \in final : x.v = v}}
FinalQ(v) == Cardinality(FinalSenders(v)) >= Q

\* The (coordinator, round) slots in which a faulty coordinator proposes.
FaultySlots == {r \in Rounds : Proposer(r) \in Faulty}

FaultyProposals(choice) ==
  {[src |-> Proposer(r), r |-> r, v |-> choice[r].v, vr |-> choice[r].vr] :
     r \in FaultySlots}

AllFaultyProposals ==
  {[src |-> p, r |-> r, v |-> v, vr |-> vr] :
     p \in Faulty, r \in Rounds, v \in Values, vr \in VRs}
  \cap {m \in [src : Faulty, r : Rounds, v : Values, vr : VRs] :
         Proposer(m.r) = m.src /\ m.vr < m.r}

AllFaultyVotes == [src : Faulty, r : Rounds, v : ValOrNil]

FaultyInit ==
  IF Equivocate
  THEN /\ propose = AllFaultyProposals
       /\ prevote = AllFaultyVotes
       /\ precommit = AllFaultyVotes
       /\ final = [src : Faulty, v : Values]
  \* Amnesic: one vote per slot. Nil votes are left out: a correct
  \* coordinator may precommit nil at any time anyway (PrecommitNil), and a
  \* nil vote never counts toward a value, so it gives an attacker nothing.
  ELSE \E pv, pc \in [Faulty -> [Rounds -> Values]],
          pr \in [FaultySlots -> [v : Values, vr : VRs]],
          fv \in [Faulty -> SUBSET Values] :
         /\ propose = {m \in FaultyProposals(pr) : m.vr < m.r}
         /\ prevote = {[src |-> p, r |-> r, v |-> pv[p][r]] : p \in Faulty, r \in Rounds}
         /\ precommit = {[src |-> p, r |-> r, v |-> pc[p][r]] : p \in Faulty, r \in Rounds}
         /\ final = UNION {{[src |-> p, v |-> v] : v \in fv[p]} : p \in Faulty}

Init ==
  /\ round = [p \in Corr |-> 0]
  /\ step = [p \in Corr |-> "propose"]
  /\ decision = [p \in Corr |-> None]
  /\ lockedValue = [p \in Corr |-> None]
  /\ lockedRound = [p \in Corr |-> -1]
  /\ validValue = [p \in Corr |-> None]
  /\ validRound = [p \in Corr |-> -1]
  /\ FaultyInit
  /\ committed = [p \in Corr |-> None]

----------------------------------------------------------------------------
(* Correct coordinators.                                                   *)

DoPrevote(p, v) ==
  /\ prevote' = prevote \cup {[src |-> p, r |-> round[p], v |-> v]}
  /\ step' = [step EXCEPT ![p] = "prevote"]

DoPrecommit(p, v) ==
  /\ precommit' = precommit \cup {[src |-> p, r |-> round[p], v |-> v]}
  /\ step' = [step EXCEPT ![p] = "precommit"]

InsertProposal(p) ==
  /\ step[p] = "propose" /\ Proposer(round[p]) = p
  /\ ~\E m \in propose : m.src = p /\ m.r = round[p]
  /\ \E v \in Values :
       /\ validValue[p] # None => v = validValue[p]
       /\ propose' = propose \cup
            {[src |-> p, r |-> round[p], v |-> v, vr |-> validRound[p]]}
  /\ UNCHANGED <<state, prevote, precommit, final>>

\* Tendermint line 22: a fresh proposal.
UponProposal(p) ==
  /\ step[p] = "propose"
  /\ \E m \in propose :
       /\ m.src = Proposer(round[p]) /\ m.r = round[p] /\ m.vr = -1
       /\ DoPrevote(p, IF lockedRound[p] = -1 \/ lockedValue[p] = m.v
                       THEN m.v ELSE Nil)
  /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                 validRound, committed, propose, precommit, final>>

\* Tendermint line 28: a re-proposal justified by a quorum of prevotes in vr.
UponProposalValidRound(p) ==
  /\ step[p] = "propose"
  /\ \E m \in propose :
       /\ m.src = Proposer(round[p]) /\ m.r = round[p]
       /\ m.vr >= 0 /\ m.vr < round[p] /\ QPV(m.vr, m.v)
       /\ DoPrevote(p, IF lockedRound[p] <= m.vr \/ lockedValue[p] = m.v
                       THEN m.v ELSE Nil)
  /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                 validRound, committed, propose, precommit, final>>

TimeoutPropose(p) ==
  /\ step[p] = "propose"
  /\ DoPrevote(p, Nil)
  /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                 validRound, committed, propose, precommit, final>>

\* Tendermint line 36: a quorum of prevotes for this round's proposal.
UponQuorumPrevotes(p) ==
  /\ step[p] \in {"prevote", "precommit"}
  /\ validRound[p] # round[p]
  /\ \E m \in propose :
       /\ m.src = Proposer(round[p]) /\ m.r = round[p] /\ QPV(round[p], m.v)
       /\ validValue' = [validValue EXCEPT ![p] = m.v]
       /\ validRound' = [validRound EXCEPT ![p] = round[p]]
       /\ IF step[p] = "prevote"
            THEN /\ lockedValue' = [lockedValue EXCEPT ![p] = m.v]
                 /\ lockedRound' = [lockedRound EXCEPT ![p] = round[p]]
                 /\ DoPrecommit(p, m.v)
            ELSE UNCHANGED <<lockedValue, lockedRound, step, precommit>>
  /\ UNCHANGED <<round, decision, committed, propose, prevote, final>>

\* Tendermint line 44 and the prevote timeout, over-approximated: a correct
\* coordinator may precommit nil at any point in its prevote step.
PrecommitNil(p) ==
  /\ step[p] = "prevote"
  /\ DoPrecommit(p, Nil)
  /\ UNCHANGED <<round, decision, lockedValue, lockedRound, validValue,
                 validRound, committed, propose, prevote, final>>

NextRound(p) ==
  /\ step[p] # "decided" /\ round[p] < MaxRound
  /\ round' = [round EXCEPT ![p] = round[p] + 1]
  /\ step' = [step EXCEPT ![p] = "propose"]
  /\ UNCHANGED <<decision, lockedValue, lockedRound, validValue, validRound,
                 committed, propose, prevote, precommit, final>>

\* Tendermint line 49, then the swarm's addition: sign one final.
Decide(p) ==
  /\ decision[p] = None
  /\ \E r \in Rounds, m \in propose :
       /\ m.src = Proposer(r) /\ m.r = r
       /\ Cardinality(Senders(PC(r, m.v))) >= Q
       /\ decision' = [decision EXCEPT ![p] = m.v]
       /\ final' = final \cup {[src |-> p, v |-> m.v]}
  /\ step' = [step EXCEPT ![p] = "decided"]
  /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                 committed, propose, prevote, precommit>>

\* What SwarmLedger.commit accepts: a quorum of finals.
Commit(p) ==
  /\ committed[p] = None
  /\ \E v \in Values : FinalQ(v) /\ committed' = [committed EXCEPT ![p] = v]
  /\ UNCHANGED <<round, step, decision, lockedValue, lockedRound, validValue,
                 validRound, propose, prevote, precommit, final>>

Next ==
  \/ \E p \in Corr :
       \/ InsertProposal(p) \/ UponProposal(p) \/ UponProposalValidRound(p)
       \/ TimeoutPropose(p) \/ UponQuorumPrevotes(p) \/ PrecommitNil(p)
       \/ NextRound(p) \/ Decide(p) \/ Commit(p)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Properties.                                                             *)

\* No two correct coordinators commit different blocks.
Agreement ==
  \A p, q \in Corr :
    committed[p] # None /\ committed[q] # None => committed[p] = committed[q]

\* Accountability of the final step: whenever two values both reach a
\* quorum of finals, at least 2Q - N coordinators signed finals for both,
\* and every one of them is faulty. Such a pair of finals is exactly the
\* evidence verifyEquivocation() accepts.
FinalAccountability ==
  \A v, w \in Values :
    (v # w /\ FinalQ(v) /\ FinalQ(w)) =>
      LET C == FinalSenders(v) \cap FinalSenders(w)
      IN Cardinality(C) >= 2 * Q - N /\ C \subseteq Faulty

\* Tendermint alone: if correct coordinators decide differently, some
\* coordinator signed two different votes for one (kind, round) slot.
\* Expected to FAIL against amnesic faults (Equivocate = FALSE): that is the
\* gap the final step closes.
VoteAccountability ==
  (\E p, q \in Corr : decision[p] # None /\ decision[q] # None
                      /\ decision[p] # decision[q]) =>
    \E a, b \in prevote \cup precommit :
      /\ a.src = b.src /\ a.r = b.r /\ a.v # b.v
      /\ (a \in prevote) = (b \in prevote)

TypeOK ==
  /\ round \in [Corr -> Rounds]
  /\ step \in [Corr -> {"propose", "prevote", "precommit", "decided"}]
  /\ decision \in [Corr -> Values \cup {None}]
  /\ committed \in [Corr -> Values \cup {None}]
=============================================================================
