# Tunisian Cards (Rami v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offline iOS hub app of Tunisian card games shipping a fully playable Rami (1 human vs 3 bots) with exact Tunisian rules, plus a "Coming soon" Chkobba card.

**Architecture:** Pure deterministic engine (plain Swift state machine, `apply(action) throws -> newState`) + `@Observable` view models + SwiftUI views. Per-game module folders behind a shared hub shell; shared `CardKit` renders the reference SVG card design natively. JSON persistence in Application Support with autosave after every action.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, iOS 17+, XcodeGen, Swift Testing for unit tests. Zero third-party dependencies, zero networking.

**Spec:** The user's prompt (full rules in conversation). Reference card art: `/Users/alaadineandolsi/Downloads/DeckCards.svg`.

## Global Constraints

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY = complete`.
- iOS deployment target 17.0. No storyboards. No third-party deps, no network entitlements, no analytics.
- RNG: `SystemRandomNumberGenerator` + Fisher–Yates in production; engine takes an injected `RandomNumberGenerator` so tests seed it. No rigging ever; bot difficulty never touches cards.
- Engine files import Foundation only (never SwiftUI).
- Exactly two configurable rules: `minimumLayDown` (default 61, range 41–101) and `eliminationScore` (default 800, range 300–2000); both frozen into the game snapshot at game start.
- 108 cards = 2×52 + 4 jokers. Counter-clockwise play = "next player to the right".
- English strings only, structured via a central `L10n` enum for future FR localization.

## File Structure

```
project.yml
README.md
Sources/
  App/
    TunisianCardsApp.swift        # @main, environment wiring
    Theme.swift                   # colors, felt background, typography, haptics helper
    L10n.swift                    # all user-facing strings
    HubView.swift                 # game hub: Rami card, Chkobba "coming soon", nav buttons
    SettingsStore.swift           # UserDefaults-backed, validated
    SettingsView.swift
    HistoryView.swift             # match list + per-match round table detail
  CardKit/
    SVGPath.swift                 # minimal SVG path-data parser -> SwiftUI Path
    CardArt.swift                 # path constants ported from DeckCards.svg (rank glyphs, pips, face figures)
    CardView.swift                # front face: frame, corner indices, pip grids, faces, joker
    CardBackView.swift            # derived back design, same frame language
  Games/Rami/
    Engine/
      Card.swift                  # Suit, Rank, Card (stable id 0..107), Deck builder
      RulesConfig.swift
      DealPattern.swift           # the 5 patterns + per-pass schedule
      Meld.swift                  # Meld + validation (runs/sets/jokers/ace/size), point values
      RamiState.swift             # full Codable snapshot incl. phase
      RamiAction.swift
      RamiEngine.swift            # apply(action) -> state, all legality checks
      Scoring.swift               # round scoring, elimination, final ranking
      Bots/
        PublicGameView.swift      # info-restricted view handed to bots (no hands, no pile order)
        HandAnalysis.swift        # meld partition search, card usefulness (shared)
        Bot.swift                 # protocol + factory by level
        BotLevel1.swift  BotLevel2.swift  BotLevel3.swift
    Persistence/
      GameStore.swift             # Application Support JSON: active game + history; autosave
      MatchRecord.swift
    ViewModels/
      RamiGameViewModel.swift     # @MainActor @Observable; bot turn loop with delays
    Views/
      RamiHomeView.swift  NewGameView.swift
      GameTableView.swift         # circular table, seats, center throws, pile, hand
      HandView.swift  SeatView.swift  ThrowAreaView.swift  MeldZoneView.swift
      DealOverlayView.swift  VoteView.swift  LayDownSheet.swift
      RoundEndView.swift  GameEndView.swift  ScoreSheetView.swift
Tests/EngineTests/
  MeldTests.swift  ThresholdTests.swift  TurnLegalityTests.swift
  DealTests.swift  ScoringTests.swift  ClosingTests.swift
  SerializationTests.swift  ReshuffleTests.swift  BotFuzzTests.swift
```

## Key Interfaces (locked)

```swift
enum Suit: String, Codable, CaseIterable, Sendable { case hearts, diamonds, clubs, spades }  // hearts/diamonds red
enum Rank: Int, Codable, CaseIterable, Sendable { case ace = 1, two ... king = 13 }
struct Card: Hashable, Codable, Identifiable, Sendable {
    enum Kind: Hashable, Codable, Sendable { case standard(rank: Rank, suit: Suit), joker }
    let id: Int          // 0..107 stable across the whole game
    let kind: Kind
    static func fullDeck() -> [Card]
}
struct RulesConfig: Codable, Sendable { var minimumLayDown: Int; var eliminationScore: Int; var botLevel: BotLevel }

struct MeldEntry: Codable, Hashable, Sendable { var card: Card; var asRank: Rank; var asSuit: Suit }
struct Meld: Codable, Hashable, Sendable {
    var entries: [MeldEntry]
    enum Kind { case run, set }
    func validate() throws -> Kind          // throws MeldError
    var thresholdValue: Int                 // ace=1 only when run starts A-2-3; J/Q/K=10; joker = represented value
}
struct TableMeld: Codable, Identifiable, Sendable { let id: UUID; var ownerSeat: Int; var meld: Meld }

enum DealPattern: String, Codable, CaseIterable, Sendable { case p1111, p1222, p2222, p2111, p3222 }
// each exposes `passes(playerCount:) -> [[Int]]` (cards per player per pass, dealer top-up included) summing 15/14/14/14

enum RamiAction: Codable, Sendable {
    case shuffle
    case deal(DealPattern)
    case declareIntent(play: Bool)            // vote phase: first actor play/propose-pass; others decline/agree
    case drawFromPile
    case takeThrow                            // only if hasLaidDown
    case takeThrowAndLayDown(melds: [Meld])   // pre-laydown: atomic take + initial laydown meeting threshold
    case layDown(melds: [Meld])
    case appendCard(MeldEntry, meldID: UUID)
    case swapJoker(meldID: UUID, realCard: Card)   // joker moves to hand; must be melded before turn ends
    case throwCard(Card)
    case startNextRound
}

enum RamiError: Error, Equatable { case notYourTurn, illegalPhase, invalidMeld(MeldError), thresholdNotMet(required: Int, got: Int), throwTakeLocked, mustLayDownWithTake, meldFull, jokerPending, cardNotInHand, ... }

struct RamiState: Codable, Sendable {
    var config: RulesConfig
    var players: [PlayerState]        // 4; seat 0 human; play order seat+1 % alive (counter-clockwise mapping done in UI)
    var dealerSeat: Int
    var phase: Phase
    var drawPile: [Card]
    var tableMelds: [TableMeld]
    var roundNumber: Int
    var lastInitialLayDownTotal: Int? // escalation chain; nil at round start
    var turnsCompletedThisRound: Int  // throw-take unlock
    var requiredLayDown: Int { (lastInitialLayDownTotal.map { $0 + 1 }) ?? config.minimumLayDown }
}
struct PlayerState: Codable, Sendable {
    var name: String; var isHuman: Bool
    var hand: [Card]; var throwStack: [Card]
    var hasLaidDown: Bool; var isEliminated: Bool
    var totalScore: Int; var roundScores: [Int?]   // nil = passed round
    var takenThrows: [Card]                        // public info for bots level 2/3
}
enum Phase: Codable, Sendable {
    case dealing(shuffles: Int)
    case vote(proposerSeat: Int, currentSeat: Int, allAgreedSoFar: Bool)
    case turn(seat: Int, TurnStage)
    case roundEnded(RoundResult)
    case matchEnded([FinalPlacement])
}
enum TurnStage: Codable, Sendable { case awaitingDraw; case awaitingThrow(drew: DrawSource, pendingJoker: Card?) }
enum DrawSource: Codable, Sendable { case pile, thrownCard }

enum RamiEngine {
    static func newGame(config: RulesConfig, names: [String], dealerSeat: Int, rng: inout some RandomNumberGenerator) -> RamiState
    static func apply(_ action: RamiAction, by seat: Int, to state: RamiState, rng: inout some RandomNumberGenerator) throws -> RamiState
    static func legalActions(for seat: Int, in state: RamiState) -> [RamiAction]  // coarse; UI/bots use it
}

protocol Bot: Sendable { func decide(view: PublicGameView, rng: inout some RandomNumberGenerator) -> RamiAction }
```

Engine rules of note (all from spec, encoded as tests):
- Throw-take globally locked until `turnsCompletedThisRound >= aliveCount` (turn 5 with 4 players, turn 4 with 3).
- Only previous alive player's top throw is takeable; take replaces draw.
- Meld size 3–5 hard cap, including appends. Set = same rank, distinct suits, 3–4 cards.
- Ace low (value 1) or high (value 10), no wraparound.
- Escalation: required = last initial laydown total + 1, reset per round.
- Closer: hand empty after final throw → round ends, closer scores 0; others: 100 flat if never laid down, else hand sum with J/Q/K/A/Joker = 10.
- Pile empty on draw → collect all throw stacks, Fisher–Yates reshuffle into new pile.
- Elimination at `>= eliminationScore`; match ends when a second player dies; ranking: survivors by score asc, then eliminated in reverse elimination order.
- Full pass vote → round abandoned, dealer rotates right, redeal; `roundScores` entry nil.

---

### Task 1: Project skeleton
- [ ] `project.yml` (app target TunisianCards + EngineTests unit test target, iOS 17, Swift 6 strict), minimal `TunisianCardsApp` + placeholder HubView, empty test. `xcodegen generate` + build + test pass on iPhone 17 sim. Commit.

### Task 2: Cards, deck, deal patterns (TDD)
- [ ] Tests: 108-card deck composition (2 copies each, 4 jokers, ids unique 0..107); Fisher–Yates shuffle uses injected RNG deterministically; each of the 5 patterns deals exactly 15/14/14/14 following its pass schedule. Implement `Card`, `DealPattern`. Commit.

### Task 3: Meld validation & values (TDD)
- [ ] Tests: valid runs 3/4/5; 6+ rejected; sets 3/4 distinct suits, duplicate suit rejected; ace low/high, K-A-2 rejected; jokers substitute + represented value; threshold values (ace=1 in A23, 10 in QKA and sets); append size cap. Implement `Meld`. Commit.

### Task 4: State machine core (TDD)
- [ ] Tests: newGame invariants; shuffle/deal phase; vote phase (all agree → redeal with next dealer; any decline → play); draw/throw invariants (14/15); take-throw lock & rules; laydown threshold + escalation; append/joker-swap legality incl. pendingJoker enforcement; closing; reshuffle-on-exhaustion. Implement `RamiState`, `RamiAction`, `RamiEngine`. Commit per test cluster.

### Task 5: Scoring, elimination, match end (TDD)
- [ ] Tests: 100-flat vs hand-count vs closer 0; elimination threshold from config; 3-player continuation (turn order skips dead, throw-take unlock 4th turn, dealer rotation skips dead); second death ends match; final ranking incl. reverse elimination order. Implement `Scoring` + engine round-end transitions. Commit.

### Task 6: Serialization round-trip (TDD)
- [ ] Tests: random mid-game states encode/decode identical (Equatable conformances); config frozen in snapshot. Commit.

### Task 7: Bots (TDD + fuzz)
- [ ] `PublicGameView` (proves no hidden info by construction), `HandAnalysis` (best partition via meld enumeration + memo), levels 1–3 per spec (L1 greedy, L2 recent-throw memory + neighbor avoidance, L3 full dead-card tracking + blocking + small-cards-early + laydown timing), vote heuristic, shuffle-count and pattern choice randomization.
- [ ] Fuzz test: ≥1000 seeded bot-vs-bot games across levels: every action legal (engine throws = failure), every game terminates under a move cap. Commit.

### Task 8: Persistence
- [ ] `GameStore` (actor): save/load/clear active game JSON; `MatchRecord` history append + in-progress record; Application Support dir. Tests for round-trip + corrupted-file resilience. Commit.

### Task 9: CardKit rendering
- [ ] `SVGPath` parser (M/L/H/V/C/S/A/Z + relatives) with tests on known paths; port rank glyphs, pips (3 sizes), face-card figures, colors/gradients from DeckCards.svg; `CardView` with frame (white face, #c7891f inner frame, shadow), mirrored corner index+pip, per-rank pip grids, face cards, derived joker + card back. Snapshot-by-eye via previews. Commit.

### Task 10: App shell — hub, settings, history
- [ ] `Theme`, `L10n`, `HubView` (Rami card + Chkobba coming-soon bounce/toast, corner buttons), `SettingsStore` + `SettingsView` (two steppers, validation, reset, "applies to next game" note), `HistoryView` (+detail). Commit.

### Task 11: Rami home + new game + view model
- [ ] `RamiHomeView` (New/Resume), `NewGameView` (level picker, rule values readout), `RamiGameViewModel`: owns state, applies human actions, runs bot loop with randomized delays, autosaves after every action, restores mid-turn. Commit.

### Task 12: Game table UI
- [ ] `GameTableView` circular layout (human bottom, bots right/top/left in CCW turn order), seat highlight sweep, center throw stacks toward seats (+history overlay), pile bottom-left with count, stats button bottom-right (ScoreSheet), mini-melds beside seats (+zoom sheet for append/joker swap), sortable hand fan, contextual action bar, dealer flow (shuffle button + 5 pattern buttons + animated card-by-card deal), vote UI, laydown selection with live validity + running total, round-end and game-end overlays, abandon confirmation, haptics. Commit per view cluster.

### Task 13: Animation & polish
- [ ] `matchedGeometryEffect` card travel (deal, draw, take, throw, laydown), spring < 400 ms, Reduce Motion → crossfades, staggered score count-ups, shuffle feedback. Commit.

### Task 14: README + final verification
- [ ] README (xcodegen generate → open → run), full test suite run, release-config build, launch in simulator and screenshot main flows. Commit.

## Self-Review Notes
- Every spec rule §2.1–§2.10, §3, §4, §6 maps to a task above (rules → 2–6, bots → 7, persistence → 8, UI → 9–13, tests → inline per task).
- Types referenced across tasks are defined in Key Interfaces.
