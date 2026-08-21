# Bot Behavior — the Humanized Rummy AI

The three bots play like real Tunisian Rummy players: human strategy, human
psychology, human imperfection. They see **only public information** — their
own hand, every throw stack, every table meld, the stock count, the scores —
never the pile order or another hand. Cards are 100% fair at every level;
difficulty changes *how well the bot plays*, never what it knows or draws.

## 1. What a bot plays for

The driving goal is **taking the fewest points**, and the best way to do that
is **closing the round** (0 points). Every decision follows this ladder:

1. **Close the round** — lay down everything plus the final throw. Always the
   preferred outcome; the bot re-estimates its realistic path to closing on
   every turn (`RummyBot.objective`).
2. If closing looks out of reach — **lay down** at the threshold and bleed
   cards onto melds every turn to shrink the residual hand.
3. Avoid at all costs — being caught with **no lay-down (+100)**. As the pile
   shrinks, an opponent runs low, the threshold escalates, or the round ages,
   an urgency signal (`roundHeat`) rises; high heat flips the bot into
   **panic mode**: bank *any* qualifying lay-down now, pretty plans be damned.

**Elimination proximity dominates.** Within ~120 points of the kill score
(scaled by the level's awareness), a bot turns deeply conservative: it lays
down as early as possible, dumps expensive cards first, and never gambles on
a big hand.

## 2. The satisfaction close

Two ways to close: the normal way (lay early, bleed to zero) and the glorious
way — **hold everything and slam all 14 cards at once**.

- Each turn the bot measures its hand's *close potential*: meld coverage plus
  how alive the leftover cards still are given remembered dead cards.
- With a **comfortable cushion** (at or below the table's median score and
  ≥ 250 from elimination) and enough personality appetite, the bot commits to
  the hunt: it refuses partial lay-downs and partial takes, keeping the hand
  hidden.
- The hunt uses **hysteresis**: committing needs a higher potential bar than
  continuing, so a nearly-complete hand stays committed instead of dithering.
- The bot **bails out** when the room heats up — pile shrinking, an opponent
  visibly close, the threshold escaping — and banks a normal lay-down.
  Experts read heat sharply and bail in time; beginners barely notice it.
- It is a personality-weighted choice: the cautious accountant almost never
  hunts, the glory-hunter loves to, and everyone hunts only when affordable.
  The fuzz suite asserts glory closes exist but stay a minority.

## 3. Defensive throwing — never feed the next player

The bot to your left is your enemy (`OpponentModel`):

- Every card the next player **took** marks a hot zone (same rank other suit,
  same suit within two ranks); every card they **declined** — anything still
  sitting in my own throw stack — marks a safe zone (expert level only).
- Takes are remembered with **decaying weight**: a fresh take burns hotter
  than an old one, and low levels remember only the last few throws.
- Before throwing, every candidate gets a **danger score** vs a
  **cost-to-keep score**. A card above the jail threshold is **jailed**:
  stuck in hand, the bot playing slightly worse for itself to starve the
  neighbor, until it turns safe, keeping it costs too much, or every option
  is hot.
- **Small cards go first** in the early round (denying cheap threshold
  progress and keeping the +100 pressure on), with discipline scaling by
  level; later — or near elimination — the expensive deadwood goes first.
- Once the next player has laid down, danger changes meaning: anything they
  can **append** to a table meld, or a real card that would **free a table
  joker**, becomes the hottest possible throw.
- All visible throws feed a **dead-card book** (both copies seen → that meld
  is impossible → the close-potential estimate drops and plans change).

## 4. Psychology

Stored per game in `RummyState.botMinds` — deterministic, persisted, pure.

- **Frustration / tilt** rises on eating 100, watching someone else close on
  a heavy hand, and bad rounds; it decays on closes and cheap rounds
  (updated in `Scoring`, at settlement). Tilt makes throws riskier (higher
  jail threshold), picks sloppier (more decision noise), lay-downs earlier
  ("just to be safe"), glory hunts abandoned sooner, and actions visibly
  snappier. It never touches information or cards.
- **Confidence** is the mirror state when calm and leading: more patience,
  more jailing, more appetite for the hunt.
- **Imperfect memory**: throws are remembered through a decaying window —
  recent sharp, old fuzzy — sized by level.
- **Inconsistency**: discards are chosen by softmax over the scored options,
  not argmax. Beginners visibly pick second-best moves; experts are
  near-greedy.
- **Personalities**: each game deals three fixed archetypes across the bot
  seats (assigned in `RummyEngine.newGame`, stable for the whole game):
  - *the cautious accountant* — banks early, rarely hunts, disciplined;
  - *the aggressive glory-hunter* — patient with laying, loves the slam;
  - *the vindictive blocker* — jails dangerous cards longest, starves you.
- **Natural pacing** (view-model layer): obvious throws come fast, takes and
  lay-downs get a thinking beat, the full slam gets a dramatic pause — and a
  tilted bot snaps its cards down ~a third faster. Moods surface as a tiny
  seat cue (😤 tilted / 😎 confident, nothing when neutral).

## 5. Level scaling

Everything above exists at every level; levels scale execution, never cards.

| Dimension | Beginner | Intermediate | Expert |
|---|---|---|---|
| Throw memory | last 3, fast decay | window of 8, moderate decay | all visible throws, full dead-card book |
| Next-player modeling | none | takes + adjacency | full take/decline + append/joker inference |
| Card jailing | rare (high threshold) | sometimes | systematic, patient |
| Small-cards-first | inconsistent (0.30) | usually (0.70) | disciplined (0.95) |
| Decision noise | high | medium | near-greedy |
| Glory judgment | reckless commit, oblivious to heat | reasonable | sharp commit bar, well-timed bailouts |
| Elimination awareness | weak (~48-pt radar) | good (~96) | precise (120) |
| Tilt | tilts hard, slow recovery | moderate | subtle, recovers fast |

All numbers live in **one config structure**: `BotWeights.resolve(level:archetype:frustration:)`
in `Sources/Games/Rummy/Engine/Bots/BotPersonality.swift`.

## 6. Architecture & guarantees

- `BotPersonality.swift` — archetypes, `BotMind` (tilt state), `BotWeights`
  (the single tuning table).
- `OpponentModel.swift` — decayed memory, danger/liveliness/dead-pair reads.
- `RummyBot.swift` — the decision ladder, glory hunt, jailing discard engine.
- `PublicGameView.swift` — the only window a bot has; other hands and the
  pile are physically absent by construction.
- Deterministic given (state + personality + RNG seed); psychology is pure
  parameters + weighted scoring, unit-tested in `BotMindTests`,
  `OpponentModelTests`, `BotStrategyTests`, `BotDiscardTests`.
- Fuzz (`BotFuzzTests`): full games per level assert zero illegal actions,
  termination, and card conservation; sanity metrics assert experts beat
  beginners at a mixed table, glory closes exist but stay a minority, and
  near-elimination bots lay down earlier than cushioned ones.
