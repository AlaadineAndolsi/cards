# Tunisian Cards

A hub of Tunisian card games for iOS. Version 1 ships **Rummy** (Tunisian Rami) — fully playable,
1 human vs 3 bots, 100% offline — with **Chkobba** teased as coming soon.

- Swift 6 (strict concurrency), SwiftUI, iOS 17+
- Pure deterministic game engine (a state machine: every action produces a new
  validated state or throws a rules error), `@Observable` view models, no
  third-party dependencies, no networking, no analytics
- Cryptographically fair deals: `SystemRandomNumberGenerator` + Fisher–Yates;
  bot difficulty changes strategy only, never the cards
- Card faces natively recreated in SwiftUI from the reference deck SVG
  (rank glyphs, suit pips, and court figures parsed from the original paths)
- Autosaved after every action to Application Support; killing the app
  mid-turn restores the exact state
- Exactly two configurable rules (Settings): minimum first lay-down total
  (default 61) and elimination score (default 800) — applied from the next
  new game only

## Build & run

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate
open Cards.xcodeproj
```

Select the **Cards** scheme and run on any iPhone simulator or device.

## Tests

Engine correctness lives in `Tests/EngineTests` (Swift Testing): meld
validation, threshold escalation, turn legality, closing, scoring,
elimination, pile reshuffle, deal patterns, serialization round-trips, and a
fuzz suite that plays 1000+ full bot-vs-bot games at every difficulty
asserting no illegal action ever occurs and every game terminates.

```sh
xcodebuild -project Cards.xcodeproj -scheme Cards \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Project layout

```
Sources/
  App/            hub shell, settings, history, theme
  CardKit/        shared card rendering (SVG-derived, reusable by Chkobba later)
  Games/Rami/
    Engine/       pure rules engine + bots (no UI imports)
    Persistence/  JSON snapshots + match history
    ViewModels/   @Observable game view model
    Views/        table, overlays, home
Tests/EngineTests/
```

Each game is a self-contained module behind the hub, so Chkobba can be added
later without refactoring.
