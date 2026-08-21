# Humanize the Rummy Bot AI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite/extend the bot decision engine so the three bots play like real Tunisian Rummy players — human strategy hierarchy (close > lay-and-bleed > never eat 100), a "satisfaction close" glory hunt, defensive throwing with card jailing, tilt/confidence psychology, fixed per-game personalities, level-scaled imperfection — with zero rule changes and cards staying 100% fair.

**Architecture:** Bot psychology lives in a Codable `BotMind` (personality + frustration) stored in `RummyState.botMinds` (optional field → old saves keep decoding; engine lazily seeds it). `RummyBot.decide` stays pure and takes the mind read-only; sticky choices (glory hunt) use hysteresis over public info instead of mutable state. Frustration updates happen purely inside `Scoring.finish` at round settlement. A new `OpponentModel` builds decayed-memory danger/dead-card books from the `PublicGameView` only. All weights sit in one internal `BotTuning` table keyed by level × personality.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`@Test`/`#expect`), XcodeGen project. Build: `xcodegen generate && xcodebuild -scheme Cards -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`. Tests: `xcodebuild test -scheme Cards -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.

**Spec:** the user's update prompt of 2026-08-21 ("Humanize the Rummy Bot AI", §1–§7) — reproduced in `BOT_BEHAVIOR.md` in prose form by Task 9.

## Global Constraints

- Bots see **only** `PublicGameView` — never pile order or other hands. No new information channels.
- No rule changes; no regression to persistence, animations, or game rules.
- Deterministic given (state + personality + RNG seed); psychology = parameters + weighted scoring, unit-testable.
- Levels scale execution quality only, never cards (§5 table).
- UI additions limited to §6: per-seat mood cue + deal-pattern ⓘ info.
- `BOT_BEHAVIOR.md` in project root documents the behavior.
- Elimination-proximity threshold: within **120** points of `config.eliminationScore` → conservative mode.

---

### Task 1: BotPersonality, BotMind, BotTuning

**Files:**
- Create: `Sources/Games/Rummy/Engine/Bots/BotPersonality.swift`
- Test: `Tests/EngineTests/BotMindTests.swift`

**Interfaces (Produces):**
```swift
enum BotArchetype: String, Codable, CaseIterable, Hashable, Sendable {
    case accountant   // cautious: low aggression, high patience, low glory
    case gloryHunter  // aggressive: high glory appetite, low patience
    case blocker      // vindictive: max jailing, defensive throws
}
struct BotMind: Codable, Hashable, Sendable {
    var archetype: BotArchetype
    var frustration: Double  // 0…1, clamped
    mutating func absorbRound(myDelta: Int, iClosed: Bool, someoneElseClosed: Bool)
    var mood: BotMood        // derived: annoyed if frustration > 0.55, confident if < 0.15
}
enum BotMood: String, Codable, Sendable { case neutral, annoyed, confident }
struct BotWeights: Sendable {  // resolved effective parameters
    var memoryWindow: Int        // throws remembered per stack (Int.max = all)
    var memoryDecay: Double      // per-position decay factor
    var noiseTemperature: Double // softmax temperature for discard choice
    var jailThreshold: Double    // danger above this jails a card
    var jailCostCap: Double      // cost-to-me above this overrides jailing
    var smallCardsDiscipline: Double // 0…1 probability weight of small-first
    var gloryAppetite: Double    // 0…1 willingness to hunt the 14-card close
    var gloryCommit: Double      // close-potential needed to start hunting
    var gloryBail: Double        // potential below which the hunt is abandoned
    var eliminationAwareness: Double
    var opponentModelDepth: Int  // 0 none, 1 takes-adjacency, 2 full take/decline
    var tiltGain: Double         // how much frustration moves per bad event
    var tiltRecovery: Double     // decay per good/neutral round
    static func resolve(level: BotLevel, archetype: BotArchetype, frustration: Double) -> BotWeights
}
```
`resolve` = per-level base table (§5) × archetype multipliers × frustration modulation (frustration ⇒ +noise, −gloryCommit patience, earlier laydown urge). All constants in this one file (§7 "one config structure").

- [ ] Write failing tests: archetype resolve differences (blocker jails more than accountant at same level), level scaling monotonicity (expert memoryWindow > intermediate > beginner; expert noise < beginner), frustration clamping, absorbRound directionality (+100 raises frustration by ~tiltGain, closing lowers it, decay applies on quiet rounds), mood boundaries.
- [ ] Implement `BotPersonality.swift`.
- [ ] Run `xcodebuild test` for `BotMindTests` — pass.
- [ ] Commit: `feat: bot personality/mind/tuning layer (archetypes, tilt, level weights)`

### Task 2: Minds in state — assignment, persistence, round-end tilt updates

**Files:**
- Modify: `Sources/Games/Rummy/Engine/RummyState.swift` (add `var botMinds: [BotMind]? = nil` — optional keeps old saves decodable, same pattern as `pendingLayDownValue`)
- Modify: `Sources/Games/Rummy/Engine/RummyEngine.swift` (`newGame`: shuffle the three archetypes across the three bot seats with the injected rng; human seat gets a neutral placeholder mind for index alignment)
- Modify: `Sources/Games/Rummy/Engine/Scoring.swift` (`finish`: update every alive bot mind from its delta/closer — pure)
- Modify: `Sources/Games/Rummy/Engine/Bots/PublicGameView.swift` (expose own `mind: BotMind` resolved with fallback default so nil-mind states still work)
- Test: `Tests/EngineTests/BotMindTests.swift` (extend)

**Interfaces:** `RummyState.botMinds: [BotMind]?`; `PublicGameView.mind: BotMind` (fallback `.init(archetype: .accountant, frustration: 0)`), `PublicGameView.eliminationScore`/`myTotalScore` conveniences if not derivable already (config + players are exposed — derivable, no additions needed).
- [ ] Tests: newGame assigns 3 distinct archetypes to seats 1–3, deterministic per seed; JSON without `botMinds` still decodes (back-compat); settleRound(+100 eater) raises that seat's frustration & closer's drops; settleFailedTake raises penalized seat's frustration hardest.
- [ ] Implement.
- [ ] Full engine test suite passes (SerializationTests included).
- [ ] Commit: `feat: per-game bot minds in state — personality assignment, tilt at settlement`

### Task 3: OpponentModel — decayed memory, danger, dead-card book

**Files:**
- Create: `Sources/Games/Rummy/Engine/Bots/OpponentModel.swift`
- Test: `Tests/EngineTests/OpponentModelTests.swift`

**Interfaces (Produces):**
```swift
struct OpponentModel {
    init(view: PublicGameView, weights: BotWeights)
    /// 0…1 probability-ish that throwing this card feeds the next player.
    func danger(of card: Card) -> Double
    /// 0…1 how completable this card's melds remain (decayed dead-card counting).
    func liveliness(of card: Card) -> Double
    /// True when both other copies of this exact rank+suit are visible.
    func isDeadPair(rank: Rank, suit: Suit) -> Bool
    /// Danger for a next player who has laid down: appendability to table melds.
    // (folded into danger(of:) — post-laydown branch)
}
```
Mechanics: takes get weight `pow(memoryDecay, ageFromEnd)` truncated at `memoryWindow`; adjacency danger (same rank other suit 0.9, same suit distance 1 → 0.8, distance 2 → 0.4) scaled by decayed weight; declines (cards sitting in my own throwStack the next player passed over) subtract safety at `opponentModelDepth ≥ 2`; if next player `hasLaidDown`, danger = appendability to any table meld (1.0 if the card legally extends one) plus joker-adjacent risk; dead-card book counts visible copies within the memory window (expert = all visible cards). depth 0 → danger constant 0.
- [ ] Tests: recent take raises adjacent-card danger more than an old take (decay); beginner depth-0 model returns 0 danger; declined zone lowers danger at expert; post-laydown appendable card scores max danger; dead pair detection over both stacks and melds; liveliness drops when neighbors are visible-dead.
- [ ] Implement (move/absorb the old `danger`/`liveliness` from `RummyBot` here).
- [ ] Tests pass.
- [ ] Commit: `feat: opponent model — decayed throw memory, take/decline danger, dead-card book`

### Task 4: Strategy core — objective tiers, glory hunt, elimination conservatism

**Files:**
- Modify: `Sources/Games/Rummy/Engine/Bots/RummyBot.swift`
- Test: `Tests/EngineTests/BotStrategyTests.swift`

**Interfaces (Produces, internal-but-testable):**
```swift
extension RummyBot {
    enum Objective: Equatable { case huntGloryClose, bleed, secureLayDown, panicLayDown }
    func objective(_ view: PublicGameView) -> Objective
    func closePotential(_ view: PublicGameView, model: OpponentModel) -> Double // 0…1
    func nearElimination(_ view: PublicGameView) -> Bool  // within 120 of the kill score
    func roundHeat(_ view: PublicGameView) -> Double // 0…1 urgency: pile shrink, opp near close, threshold escalation, round age
}
func decide(_ view: PublicGameView, mind: BotMind, rng: inout some RandomNumberGenerator) -> RummyAction
// old decide(view:rng:) kept as a shim → neutral mind, so fuzz call sites keep compiling
```
Rules encoded:
- `nearElimination` → `secureLayDown/panicLayDown` always; lays the first qualifying partition immediately, initialPartition stops preferring closable leftovers, discard prefers dumping high values, glory hunt forbidden.
- `objective` ladder: glory hunt iff `!hasLaidDown && cushion && closePotential ≥ gloryCommit(weights)`; hunting **suppresses** partial laydowns (returns throw instead) until potential < `gloryBail` or `roundHeat` crosses the bail line — hysteresis (commit needs a higher bar than bail) makes the hunt sticky without stored state. Cushion = own score in bottom half of alive totals AND ≥ 250 from elimination.
- `roundHeat` inputs: drawPileCount fraction, min opposing `handCount` (≤ 4 → hot), any opponent laid + shedding, `requiredLayDown` escalated above the base, `turnsCompletedThisRound / aliveCount` age. High heat + no laydown yet → `panicLayDown` (lay anything qualifying now, break pretty plans: skip the keep-closable trimming).
- closePotential: coverage fraction of `bestPartition(maximizeCoverage:)` + per-missing-card liveliness from the model, minus dead-pair hits.
- [ ] Tests (crafted `PublicGameView`s via StateBuilder): near-elimination bot lays a qualifying partition that the cushioned bot holds; glory-committed bot with 13/14 covered and cushion throws instead of laying; same hand with hot round (pile < 15) bails and lays; escalated threshold + old round → panic lay; beginner glory judgment is reckless (commit bar lower) vs expert bail sharper.
- [ ] Implement; keep every existing legality guard (first-cycle lock, pendingJoker, closable-hand floor) intact.
- [ ] `BotStrategyTests` + full suite pass.
- [ ] Commit: `feat: bot strategy tiers — close/bleed/secure ladder, glory hunt with bailouts, elimination fear`

### Task 5: Human discard engine — jailing, small-first, softmax noise

**Files:**
- Modify: `Sources/Games/Rummy/Engine/Bots/RummyBot.swift` (`chooseDiscard`, `discardScore` rebuilt on OpponentModel)
- Test: `Tests/EngineTests/BotDiscardTests.swift`

Mechanics:
- Per candidate: `throwScore = costToKeep − dangerPenalty`. `costToKeep` = synergy loss (existing pairSynergy × liveliness) + handValue pressure (early & next-not-laid: small-first bonus scaled by `smallCardsDiscipline`; late or near elimination: high-value dump).
- **Jailing**: `danger > jailThreshold` → candidate excluded unless every legal candidate is jailed or its `costToKeep > jailCostCap` or stalemate breaker active. Blocker archetype jails at a lower threshold and holds longer (weights).
- **Softmax selection**: instead of argmax, sample among legal candidates with `p ∝ exp(score/noiseTemperature)`; beginner temperature high (visible mistakes), expert near-greedy. Uses the injected rng only.
- Keep: never throw joker, never throw penalized while legal exists, stalemate breaker at `turns > 30 × aliveCount`.
- [ ] Tests: dangerous card stays in hand across a turn while a safe near-equal exists (jailed); jail overridden when cost exceeds cap; early-round small-first at expert (throws 3 over K when both safe deadwood) vs late-round reversal; beginner with fixed seed occasionally picks 2nd-best (statistical: over 200 seeded draws expert picks top choice ≥ 95%, beginner ≤ 80%); joker never thrown; penalized-throw guard intact.
- [ ] Implement.
- [ ] Tests + full suite pass.
- [ ] Commit: `feat: human discard engine — card jailing, small-cards-first, softmax imperfection`

### Task 6: ViewModel — minds through the loop, natural pacing, mood exposure

**Files:**
- Modify: `Sources/Games/Rummy/ViewModels/RummyGameViewModel.swift`

Changes:
- `runBots()`: pull `state.botMinds?[seat]`, call the new `decide(view:mind:rng:)`. Compute the action **first**, then pause `pauseForBotAction(action:seat:)` before applying: base by kind (throw after obvious deadwood ≈ 0.5–0.8 s; takeThrow / layDown / takeThrowAndLayDown ≈ 1.2–1.9 s "thinking"; closing lay ≈ 2.0 s beat), multiplied by `(1 − 0.35 × frustration)` — tilted bots snap. Cap ≤ 2 s, keep dealing/vote pacing as-is.
- Expose `func botMood(seat: Int) -> BotMood?` (nil for human/eliminated) for the seat views.
- [ ] Implement; build succeeds; play a few bot turns in simulator confirming pacing feels alive and no stalls.
- [ ] Commit: `feat: bots think like humans — difficulty-paced timing, tilt-snappy moves`

### Task 7: Visible flavor — seat mood cue + deal-pattern ⓘ

**Files:**
- Modify: `Sources/Games/Rummy/Views/TableSubviews.swift` (SeatView: tiny mood dot/emoji — 😤 annoyed / 😎 confident, hidden when neutral; subtle, 10–11 pt, next to the name)
- Modify: `Sources/Games/Rummy/Views/TableOverlays.swift` (DealControlsView: small ⓘ button toggling a compact explanation card)
- Modify: `Sources/App/L10n.swift` (pattern-info copy: the pattern only changes the dealing rhythm — which cards of the already-shuffled deck land where; same shuffle + different pattern = different hands, but the shuffle is truly random so **no pattern is statistically luckier**; a traditional ritual like cutting the deck)
- Modify: `Sources/Games/Rummy/Views/GameTableView.swift` (pass mood into SeatView)
- [ ] Implement; build; simulator screenshot check (mood chip on a tilted bot via crafted save, ⓘ panel opens/closes and doesn't collide with the pattern grid).
- [ ] Commit: `feat: seat mood cues and honest deal-pattern info button`

### Task 8: Fuzz + sanity metrics

**Files:**
- Modify: `Tests/EngineTests/BotFuzzTests.swift`

Changes:
- Driver gains minds: bots per seat may differ in level (`bots: [RummyBot]`), minds flow from state; per-game stats returned (`struct GameStats { placements, avgBotRoundPoints[level], gloryCloses, totalCloses, firstLayTurnByScoreBand }`). Glory close counted when a round's closer laid ≥ 12 cards in one action having not laid before.
- Tests:
  - Legality/termination fuzz raised to **1000 seeds per level** (spec: thousands of full games; keep `actionCap`).
  - **Skill ordering**: mixed table (2 expert seats vs 2 beginner seats) over 200 seeded games → experts' mean total points strictly lower and mean placement better.
  - **Glory hunts minority**: across 300 expert games, gloryCloses ≥ 1 and gloryCloses/totalCloses < 0.35.
  - **Elimination fear**: mean turn-of-first-laydown for bots within 120 of elimination < mean for cushioned bots (aggregate over runs).
- [ ] Implement stats plumbing + assertions; run the full suite (long) — all green; tune weight constants if a metric fails (constants live only in `BotPersonality.swift`).
- [ ] Commit: `test: level-ordering, glory-minority, elimination-fear fuzz metrics at 1000 games/level`

### Task 9: BOT_BEHAVIOR.md + final verification

**Files:**
- Create: `BOT_BEHAVIOR.md` (project root)

Content: the behavior contract in prose — objective hierarchy, satisfaction close, defensive throwing/jailing, psychology (tilt/confidence/memory/noise/personalities/pacing), level-scaling table (§5 reproduced), fairness guarantees, architecture map (files + one-config-structure pointer), test guarantees.
- [ ] Write the doc.
- [ ] Full test suite + build one last time; simulator smoke of one bot round.
- [ ] Commit: `docs: BOT_BEHAVIOR.md — the humanized bot contract` and push.

## Self-Review Notes

- §1 hierarchy → Task 4 objective ladder; §2 glory → Task 4; §3 defense/jailing/small-first → Tasks 3+5; §4 psychology → Tasks 1+2+5 (noise) + 6 (pacing); §5 scaling → Task 1 tables asserted in Tasks 1/5/8; §6 flavor → Task 7; §7 engineering → minds-in-state purity (Tasks 1–2), one config structure (Task 1), fuzz metrics (Task 8); root md → Task 9. No uncovered spec lines found.
- Type consistency: `BotMind`, `BotWeights`, `BotMood`, `OpponentModel`, `decide(view:mind:rng:)` used identically across tasks.
