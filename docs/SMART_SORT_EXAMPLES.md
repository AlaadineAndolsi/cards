# Smart sort — worked examples

Alaadine's ground-truth examples of what the smart sort (`smartOrder` in
`Sources/Games/Rummy/ViewModels/RummyGameViewModel.swift`) must produce.
**Read this file before changing the algorithm. Every time Alaadine gives a
new example (screenshot or description), add it here** with the hand, the bad
output, the wanted output, and the rule(s) the example teaches — then encode
it as a test in `Tests/EngineTests/SmartSortTests.swift`.

Notation: cards big-to-small left-to-right, `·` separates blocks.

---

## Example 1 — near-runs beat rank-mates; a joker fills only ONE hole; the leading weak card promotes (2026-08-23)

**Hand:** Joker, K♦, Q♣, J♠, 10♣, 10♦, 9♠, 9♦, 7♦, 3♦, 2♦, 2♠, 2♥, 6♠ (round 1, empty table)

**Got (bad):**
Joker, K♦, 10♣, 10♦, 9♠, 9♦, 7♦, 3♦, 2♦, 2♠, 2♥, Q♣, J♠, 6♠

**Wanted** (screenshot showed the joker second; Alaadine corrected: *"the
joker placement is wrong, it should be last card"* — which example 6 later
clarified means the far LEFT end of the fan, where jokers always sit):
Joker · K♦ · Q♣ 10♣ · J♠ 9♠ · 10♦ 9♦ 7♦ · 3♦ 2♦ 2♥ 2♠ · 6♠

**What went wrong and the rules learned:**

1. **A card prefers its own suit's near-run over attaching as a rank-mate.**
   10♣ was glued beside 10♦ and 9♠ beside 9♦, which orphaned Q♣ and J♠ into
   the loose tail. Wanted: Q♣-10♣ and J♠-9♠ each form their own one-gap
   near-run block. (Fix: build suit chains with gap ≤ 2 *before* rank-mate
   attachment.)

2. **A gap of three never bridges, joker or not.** K♦ was welded onto
   10♦-9♦-7♦ because "a joker relaxes the end gap to 3" — but K over 10
   means TWO missing cards (Q and J); one joker fills one hole only. Max
   bridgeable gap is 2 (one missing card), always.

3. **Jokers always print at the far LEFT of the hand** (settled by
   example 6). A joker in hand still promotes the best weak cards (rank
   ≥ 5) to a combo block: a two-suit rank group always; a lone card only
   when it outranks every combo and leads the hand — that is why the
   otherwise-loose K♦ heads the blocks here instead of sinking into the
   weak tail.

4. Everything else already held: blocks order by top card (13 · 12 · 11 ·
   10), the 2♦-2♠-2♥ set clusters with 3♦ heading it, junk (6♠) last.

Test: `SmartSortTests.nearRunsBeatRankMatesAndJokerClaimsTopWeakCard`

---

## Example 2 — a weak pair promotes to the left; 8-6 of a suit is a near-run (2026-08-24)

**Hand:** Joker, Q♦, J♦, 9♣, 9♠, 8♣, 8♥, 2♥, 2♦, 2♦, 2♣, K♣, K♥, 6♥
(screenshot was from the pre-example-1 build)

**Got (bad, old build):**
Joker, Q♦, J♦, 9♣, 9♠, 8♣, 8♥, 2♥, 2♦, 2♦, 2♣, K♣, K♥, 6♥ — kings and 6♥
stranded at the far right.

**Wanted:** *"both kings should be at left after the joker, and the 6♥
should be after the 8♥"*:
Joker K♥ K♣ · Q♦ J♦ · 9♠ 9♣ 8♣ · 8♥ 6♥ · 2♥ 2♣ 2♦ 2♦

**Rules learned / confirmed:**

1. **A weak two-suit pair promotes to its own combo block at its rank.**
   K♣+K♥ (13) outranks every run here, so the kings sit at the left,
   right after the joker (which always prints far left — example 6
   clarified the joker never moves elsewhere).

2. **8-6 of one suit (one missing card) is a near-run block** — confirmed;
   the gap ≤ 2 chain rule from example 1 already covers 8♥-6♥.

Test: `SmartSortTests.jokerLeadsAReadyMeldWithAWeakPair`

---

## Example 3 — a dissolved low fragment keeps its cards together: 3♦ prints before 2♦ (2026-08-24)

**Hand:** Joker, Joker, K♠, K♣, 7♣, 7♦, 5♥, 2♦, 2♥, A♥, Q♥, 9♠, 4♠, 3♦
(screenshot again from the old build)

**Got (bad, old build):**
Joker, Joker, K♠, K♣, 7♣, 7♦, 5♥, 2♦, 2♥, A♥, Q♥, 9♠, 4♠, 3♦ — 2♦ glued
beside 2♥ as a rank-mate of the A♥-2♥ block, 3♦ stranded at the far right.

**Wanted:** *"the 3 diamonds should be before the 2 of diamonds, left to
right"* — 3♦ immediately left of 2♦.

**Rule learned:**

1. **Rank-mate attachment must not rip a card away from its immediate
   same-suit neighbor.** 3♦-2♦ is a dissolved low fragment (example 1),
   so it lives in the weak clusters — but it lives there TOGETHER, 3
   before 2. A card whose suit holds its direct neighbor (±1) among the
   leftovers never attaches as a rank-mate elsewhere; the number clusters
   then chain them (the 3-2 cluster counts as combo material and prints
   before lone singles). This extends example 1's "near-runs beat
   rank-mates" down into fragments too weak to be runs.

**Resulting order (current algorithm):**
Joker Joker · A♥ Q♥ · K♠ K♣ · 7♣ 7♦ · 3♦ 2♦ 2♥ 9♠ 5♥ 4♠
(jokers far left; the ace sits high beside Q♥ per example 5; kings and
sevens promoted by the two-joker pair rule; the 9♠ is NOT promoted — it
would not lead the hand, per example 6.)

Test: `SmartSortTests.dissolvedLowFragmentKeepsThreeBeforeTwo`

---

## Example 4 — complete sets beat runs; the run leftover lines up under the set (2026-08-24)

**Hand:** K♦, K♥, K♥, K♠, Q♦, Q♣, Q♠, J♠, 6♦, 5♦, 5♠, 3♠, 8♣, 4♥ (no joker)

**Got (bad, old build):**
K♥ K♥ K♠ Q♣ Q♠ J♠ · K♦ Q♦ · 6♦ 5♦ 5♠ · 8♣ 4♥ 3♠ — the spade run kept
K♠/Q♠, splitting the kings and queens across the hand.

**Wanted:**
K♦ K♥ K♥ K♠ · Q♦ Q♣ Q♠ · J♠ · 6♦ 5♦ · 5♠ 3♠ · 8♣ 4♥

**Rules learned:**

1. **A complete set (3+ distinct suits of one rank) claims its cards BEFORE
   any suit chain forms — even breaking a complete run.** Four kings +
   three queens (7 layable cards) beat K♠-Q♠-J♠ + K♦-Q♦. Claiming for a
   set is never worse: a broken run leaves at most an equal fragment.
   Duplicate copies (the second K♥) ride along inside the set block.

2. **Low ranks (2–4) never form strong sets** — example 1 already put the
   three-suit set of 2s in the weak tail. The set rule applies to rank ≥ 5
   only; low sets live in the number clusters.

3. **A leftover card one below a set that holds its suit lines up beneath
   it**: J♠ prints right after Q♦-Q♣-Q♠. Sets print diamonds→spades so the
   tail-mate chains on its suit (…Q♠ J♠).

Test: `SmartSortTests.completeSetsClaimCardsBeforeRuns`




---

## Example 5 — ace-king if possible, if not 2-ace (2026-08-24)

**Hand:** Joker, K♠, 10♥, 10♠, 7♠, 6♥, 6♣, 5♣, 3♣, 2♥, 2♠, A♠, 9♦, 4♥

**Got (bad, old build):** …2♥ 2♠ A♠… — the ace glued low beside the 2♠.

**Wanted:** *"ace king if possible, if not 2-ace"* — A♠ beside K♠.

**Rules learned:**

1. **The ace prefers its high seat**: with a same-suit K (or Q within the
   one-hole gap) in hand, the ace joins the A-K line and the low 2 goes
   back to the weak clusters. Only a complete low run (A-2-3) still keeps
   the ace low.

**Resulting order:** Joker · A♠ K♠ · 10♠ 10♥ · 6♥ 6♣ 5♣ 3♣ 2♠ 2♥ · 9♦ 7♠ 4♥
(the twos pair lines up under the club run's 3 — pair-under-run tailing.)

Test: `SmartSortTests.acePrefersKingOverTwo`

---

## Example 6 — the joker is ALWAYS far left; a mid-hand single never promotes (2026-08-24)

**Hand:** Joker, K♣, Q♣, J♦, 10♣, 10♥, 10♠, 9♥, 9♣, 4♣, 3♣, 3♥, 3♦, 8♠
(first feedback on the new build)

**Got (bad):** K♣ Q♣ J♦ 10♣ 10♥ 10♠ 9♥ 9♣ 4♣ 3♣ 3♥ 3♦ 8♠ Joker — joker at
the right end, lone J♦ promoted between the K-Q block and the 10-set.

**Wanted:** *"the joker always on left — why is it on right?"*:
Joker · K♣ Q♣ · 10♣ 10♠ 10♥ 9♥ 9♣ · 4♣ 3♣ 3♥ 3♦ · J♦ 8♠

**Rules learned:**

1. **Jokers ALWAYS print at the far left of the hand.** This retroactively
   clarifies example 1's "should be last card": it meant the left end of
   the fan. No trailing jokers, no jokers inside blocks — ever.

2. **A lone weak card only promotes when it would LEAD the hand.**
   Example 1's K♦ (13) outranked every block; this J♦ (11) sits below the
   K♣-Q♣ block, so it stays in the weak clusters (J♦ then 8♠, by rank).

3. **A set exits on its tail-mates' suit**: 10♣ 10♠ **10♥** · 9♥ 9♣ — the
   heart ten closes the set so the line connects to the heart nine.

4. (Implementation fallout, consistent with rule "one missing card": a
   chain carries at most ONE hole — 6-4-2 of a suit is junk, not a run,
   and K-J-9-7 splits into K-J and 9-7.)

Test: `SmartSortTests.jokerLeftAndMidHandSingleStaysWeak`

---

## Game rule (same session, not a sort example): throw with only jokers left auto-closes

*"When I throw a card and I have only jokers remaining, the round is over —
same as if I placed the jokers first then threw. No need to waste time
placing jokers before I throw."* Implemented in `RummyEngine.throwCard`:
after the throw, remaining all-joker hands auto-append each joker to a table
meld with room and the round settles with the thrower as closer. If no meld
can take them, the turn passes normally.
Tests: `ClosingAndScoringTests.throwWithOnlyJokersLeftAutoClosesTheRound`,
`throwWithJokersButNoTableRoomDoesNotClose`.

---

## UI rules (same session): the placement window is never stale

1. *"When another player lays, my cards didn't show on the melds popup
   until my turn."* — The candidate strip now shows your placeable cards
   the moment melds hit the table, any turn. Before your throw step a tap
   RESERVES the card (placeable lock); placing itself still opens on your
   turn (drops spring back until then).
2. *"When I place a joker and a card now fits (Q-J-10 + joker as 9 → the
   8), it should appear immediately."* — Placing a card from the hand fan
   no longer closes the window, so every placement leaves the popup open
   with the freshly-fitting cards showing.

---

## Game rule (same session): a same-rank set that fills to four is destroyed

Placing the 4th card on a set (3-3-3 + 3, K-K-K + K, joker-J-J + J…)
completes it — the whole set bursts off the table, jokers included, with a
short center-stage animation ("Set complete — destroyed"). The cards go to
`RummyState.destroyedCards`: invisible to everyone, cleared each round, and
folded back in when the exhausted draw pile is rebuilt from the throws.
Applies to appends, direct lays of a 4-set, and the joker auto-close.
Tests: `SetDestructionTests` in ScoringTests.swift.

---

## Hand rule (same session): a purchased card takes a locked joker's seat

*"When my locked series has a joker inside and I purchase or take the card
the joker replaces, the new card replaces the joker and the joker comes back
free to the left of my cards."* Implemented in
`RummyGameViewModel.swapFreshIntoLockedJokers`: on every draw/take, fresh
cards are checked against locked melds' joker entries (asRank/asSuit match);
the card slides into the seat, the series keeps its shape, and the freed
joker pops out unlocked at the left of the free cards (jokers-left doctrine).
Tests: `SortOnPurchaseTests.purchasedCardTakesALockedJokersSeat`,
`takenThrowTakesALockedJokersSeat`.

---

## Hand rule (same session): a throw out of an organized series bounces once

*"When I throw a card that's in an organized series that is not locked (say
an arranged 6-5-4), consider the first throw a mistake and return the card
with an attention message."* Implemented in `RummyGameViewModel.apply`: if
the thrown card plus its immediate fan neighbors (three unlocked cards, as
arranged) form a valid meld, the throw bounces with "Attention — X is part
of a series. Throw it again if you mean it." Repeating the exact same throw
confirms and goes through. Locked/reserved cards are excluded (they have
their own protections), and only true melds trigger — near-runs with gaps
never bounce. Tests: `SeriesThrowGuardTests` in SortOnPurchaseTests.swift.

---

## Game rule fix (2026-08-24): no first throw can ever be picked

Bug: the global take unlock ("everyone played once", `turnsCompletedThisRound
>= aliveCount`) let the 5th turn's player take the 4th player's FIRST throw.
Rule per Alaadine: *"all 4 first throws cannot be picked."* Fix: each
player's first thrown card of the round is recorded
(`PlayerState.firstThrowID`) and is permanently untakeable — even when later
takes drain the stack back down to it. Cleared on pile reshuffle (the card
recycled) and at round reset. `takeableThrow(for:)` returns nil for it, so
the UI highlight and the bots inherit the rule; the engine's
`takePreviousThrow` enforces it with `throwTakeLocked`.
Tests: `aFirstThrowIsNeverTakeableEvenAfterGlobalUnlock`,
`takesNeverReachTheProtectedFirstThrow` in TurnLegalityTests.swift.

---

## Example 7 — a longer run outbids the set; rank-mates take END seats; a single only promotes when it CROWNS (2026-08-24)

**Hand:** Joker, A♣, 9♥, 8♥, 7♥, 7♦, 7♣, 6♥, 6♣, 4♠, 4♦, 3♦, 3♥, Q♥
(first feedback from the physical iPhone build)

**Got (bad):**
Joker · A♣ · 9♥ 8♥ 6♥ 6♣ · 7♦ 7♣ 7♥ · 4♠ 4♦ 3♦ 3♥ · Q♥ — the 7s set
claimed 7♥ and broke the complete heart run; A♣ promoted to the front.

**Wanted:**
Joker · 9♥ 8♥ 7♥ 6♥ · 7♦ 7♣ 6♣ · 4♠ 4♦ 3♦ 3♥ · A♣ · Q♥

**Rules learned:**

1. **A set member refuses the claim when its own suit runs LONGER through
   it than the set is wide.** 7♥ sits inside 9-8-7-6 (four melded cards)
   — better than the three-card set of 7s, so the set dies (down to two
   suits). Example 4 still holds: the kings' K-Q-J run was only EQUAL in
   length, and an equal run never outbids a set.

2. **A rank-mate prefers an END seat.** 7♦ prints beside the 7♣-6♣
   block's top, not buried mid-way inside the heart run. Mid-run anchors
   are only a fallback when no run offers the value at an edge.

3. **A lone single promotes only when it CROWNS the leading block —
   exactly one rank above it.** Example 1's K♦ sat one above the Q♣-10♣
   block; this A♣ over a 9-block stays in the weak tail (clusters put it
   after the paired 4s/3s, before the lone Q♥). This unifies examples 1,
   3, 6 and 7.

Test: `SmartSortTests.runThroughASetMemberBeatsTheSet`

---

## UI rule (2026-08-24): chained placeability — the K♠ bridges the A♠

*"With Q-J-10 on the table and ace-king of the same suit in hand, I should
be able to select BOTH as placeable, lock them blue, and see them together
on the melds popup — today only the king counts."* Implemented via
`RummyGameViewModel.chainFittingMelds/chainToFit`: a card is placeable when
other free hand cards (never jokers — spending a joker stays an explicit
move; never series-locked cards) can extend the meld until it fits. Both
cards show in the popup, both long-press-lock blue, and placing the chained
card lays its prerequisites on the way (dropping the A♠ appends the K♠
first). The wasted-throw penalty stays direct-fit only (engine untouched).
Tests: `ChainedPlacementTests` in SortOnPurchaseTests.swift.
