import SwiftUI

/// Native recreation of the reference deck design (140×190 design space):
/// layered rounded-rect frame with the amber inner border, custom rank glyphs,
/// suit pips in the classic grids, and the original court figures — mirrored
/// top/bottom exactly like the source art. Crisp at every size.
struct CardView: View {
    let card: Card
    /// Adds an upright index in the top-right corner — used for fanned hands
    /// where only a card's right side stays visible.
    var extraTopRightIndex = false

    static let designSize = CGSize(width: 140, height: 190)
    static let aspectRatio: CGFloat = 140.0 / 190.0

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = min(size.width / Self.designSize.width, size.height / Self.designSize.height)
            context.scaleBy(x: scale, y: scale)
            CardRenderer.drawFront(card: card, in: &context, extraTopRightIndex: extraTopRightIndex)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityLabel(accessibilityName)
    }

    private var accessibilityName: String {
        if card.isJoker { return "Joker" }
        guard let rank = card.rank, let suit = card.suit else { return "Card" }
        return "\(rank.label) of \(suit.rawValue)"
    }
}

/// The face-down back, derived from the same frame language.
struct CardBackView: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let scale = min(size.width / CardView.designSize.width, size.height / CardView.designSize.height)
            context.scaleBy(x: scale, y: scale)
            CardRenderer.drawBack(in: &context)
        }
        .aspectRatio(CardView.aspectRatio, contentMode: .fit)
        .accessibilityLabel("Face-down card")
    }
}

// MARK: - Renderer

enum CardRenderer {
    private static let red = Color(red: 1, green: 0, blue: 0)
    private static let amber = Color(red: 0xC7 / 255.0, green: 0x89 / 255.0, blue: 0x1F / 255.0)

    // Pip grids from the reference symbols: `top` mirrors around (69, 95),
    // `center` stays upright.
    private static let pipLayout: [Rank: (top: [CGPoint], center: [CGPoint])] = [
        .two: ([CGPoint(x: 69, y: 40)], []),
        .three: ([CGPoint(x: 69, y: 40)], [CGPoint(x: 69, y: 83.5)]),
        .four: ([CGPoint(x: 49, y: 40), CGPoint(x: 89, y: 40)], []),
        .five: ([CGPoint(x: 49, y: 36), CGPoint(x: 89, y: 36)], [CGPoint(x: 69, y: 83.5)]),
        .six: ([CGPoint(x: 49, y: 36), CGPoint(x: 89, y: 36)],
               [CGPoint(x: 49, y: 83.5), CGPoint(x: 89, y: 83.5)]),
        .seven: ([CGPoint(x: 49, y: 36), CGPoint(x: 89, y: 36)],
                 [CGPoint(x: 49, y: 83.5), CGPoint(x: 89, y: 83.5), CGPoint(x: 69, y: 60)]),
        .eight: ([CGPoint(x: 49, y: 36), CGPoint(x: 89, y: 36),
                  CGPoint(x: 49, y: 69), CGPoint(x: 89, y: 69)], []),
        .nine: ([CGPoint(x: 49, y: 36), CGPoint(x: 89, y: 36),
                 CGPoint(x: 49, y: 65), CGPoint(x: 89, y: 65)], [CGPoint(x: 69, y: 83.5)]),
        .ten: ([CGPoint(x: 49, y: 36), CGPoint(x: 69, y: 54), CGPoint(x: 89, y: 36),
                CGPoint(x: 49, y: 72), CGPoint(x: 89, y: 72)], []),
    ]

    static func drawFront(card: Card, in context: inout GraphicsContext, extraTopRightIndex: Bool = false) {
        drawFrame(in: &context)
        if card.isJoker {
            drawJoker(in: &context)
            return
        }
        guard let rank = card.rank, let suit = card.suit else { return }
        if extraTopRightIndex {
            let ink = suit.isRed ? red : Color.black
            var corner = context
            corner.translateBy(x: 100, y: 0)
            if let glyph = CardArt.rankGlyphs[rank] {
                fill(glyph, with: .color(ink), in: &corner)
            }
            if let large = CardArt.largeSuit[suit] {
                fill(large, with: .color(ink), in: &corner)
            }
        }
        // Top-left corner content, then the same rotated 180° about the center.
        drawHalf(rank: rank, suit: suit, in: &context)
        var mirrored = context
        mirrored.translateBy(x: 138, y: 190)
        mirrored.rotate(by: .degrees(180))
        drawHalf(rank: rank, suit: suit, in: &mirrored)
        // Upright extras: center pips or the ace's large emblem.
        let ink = suit.isRed ? red : Color.black
        if rank == .ace, let d = CardArt.aceSuit[suit] {
            var ace = context
            ace.translateBy(x: 69, y: 55)
            fill(d, with: .color(ink), in: &ace)
        } else if let layout = pipLayout[rank], let d = CardArt.smallSuit[suit] {
            for point in layout.center {
                var pip = context
                pip.translateBy(x: point.x, y: point.y)
                fill(d, with: .color(ink), in: &pip)
            }
        }
    }

    /// Corner index (glyph + large pip), the top pip grid, and court figures.
    private static func drawHalf(rank: Rank, suit: Suit, in context: inout GraphicsContext) {
        let ink = suit.isRed ? red : Color.black
        if let glyph = CardArt.rankGlyphs[rank] {
            fill(glyph, with: .color(ink), in: &context)
        }
        if let large = CardArt.largeSuit[suit] {
            fill(large, with: .color(ink), in: &context)
        }
        if let layout = pipLayout[rank], let small = CardArt.smallSuit[suit] {
            for point in layout.top {
                var pip = context
                pip.translateBy(x: point.x, y: point.y)
                fill(small, with: .color(ink), in: &pip)
            }
        }
        if let figure = facePaths(rank: rank, red: suit.isRed) {
            var figureContext = context
            switch rank {
            case .king:
                figureContext.translateBy(x: 39, y: 8)
                figureContext.scaleBy(x: 0.85, y: 0.85)
            case .queen:
                figureContext.translateBy(x: 11, y: -23)
                figureContext.scaleBy(x: 0.85, y: 0.85)
            default:
                figureContext.translateBy(x: -86, y: -7)
            }
            for facePath in figure {
                fill(facePath.d, with: shading(for: facePath.fill, d: facePath.d), in: &figureContext)
            }
        }
    }

    private static func facePaths(rank: Rank, red: Bool) -> [CardArt.FacePath]? {
        switch rank {
        case .king: red ? CardArt.redking : CardArt.blackking
        case .queen: red ? CardArt.redqueen : CardArt.blackqueen
        case .jack: red ? CardArt.redjack : CardArt.blackjack
        default: nil
        }
    }

    // MARK: Frame

    private static func drawFrame(in context: inout GraphicsContext) {
        func rounded(_ x: CGFloat, _ y: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x, y: y, width: 135, height: 185), cornerRadius: 16)
        }
        context.fill(rounded(4.15, 4.15), with: .color(Color(white: 0.5).opacity(0.55)))
        context.fill(rounded(1, 1), with: .color(Color(red: 0xE7 / 255.0, green: 0xE7 / 255.0, blue: 0xE7 / 255.0)))
        context.fill(rounded(3, 3), with: .color(amber))
        context.fill(rounded(2, 2), with: .color(.white))
    }

    // MARK: Joker (derived design, same visual language)

    static func drawJoker(in context: inout GraphicsContext) {
        // Corner index: vertical JOKER lettering in the amber/red palette.
        func drawCorner(_ context: inout GraphicsContext) {
            let letters = Array("JOKER")
            for (index, letter) in letters.enumerated() {
                let text = Text(String(letter))
                    .font(.system(size: 13, weight: .heavy, design: .serif))
                    .foregroundStyle(index.isMultiple(of: 2) ? red : amber)
                context.draw(text, at: CGPoint(x: 16, y: 20 + CGFloat(index) * 13.5))
            }
        }
        drawCorner(&context)
        var mirrored = context
        mirrored.translateBy(x: 138, y: 190)
        mirrored.rotate(by: .degrees(180))
        drawCorner(&mirrored)

        // Center: jester hat drawn from three petals with pom-poms, over a
        // diamond of the four suit pips.
        var center = context
        center.translateBy(x: 69, y: 95)
        let petalColors = [red, amber, Color(red: 0, green: 0, blue: 0.5)]
        let angles: [Double] = [-50, 0, 50]
        for (color, angle) in zip(petalColors, angles) {
            var petal = Path()
            petal.move(to: CGPoint(x: -12, y: 6))
            petal.addQuadCurve(
                to: CGPoint(x: 0, y: -34),
                control: CGPoint(x: angle * 0.45 - 6, y: -22))
            petal.addQuadCurve(to: CGPoint(x: 12, y: 6), control: CGPoint(x: angle * 0.45 + 6, y: -22))
            petal.closeSubpath()
            var rotated = center
            rotated.rotate(by: .degrees(angle * 0.55))
            rotated.fill(petal, with: .color(color))
            rotated.fill(
                Path(ellipseIn: CGRect(x: angle * 0.42 - 3.5, y: -38, width: 7, height: 7)),
                with: .color(color == amber ? red : amber))
        }
        center.fill(
            Path(roundedRect: CGRect(x: -16, y: 4, width: 32, height: 7), cornerRadius: 3.5),
            with: .color(amber))
        let suits: [(Suit, CGPoint)] = [
            (.hearts, CGPoint(x: -25, y: 22)), (.diamonds, CGPoint(x: -8, y: 30)),
            (.clubs, CGPoint(x: 8, y: 30)), (.spades, CGPoint(x: 25, y: 22)),
        ]
        for (suit, point) in suits {
            guard let d = CardArt.smallSuit[suit] else { continue }
            var pip = context
            pip.translateBy(x: 69 + point.x, y: 95 + point.y)
            pip.scaleBy(x: 0.62, y: 0.62)
            fill(d, with: .color(suit.isRed ? red : .black), in: &pip)
        }
    }

    // MARK: Back (derived design)

    static func drawBack(in context: inout GraphicsContext) {
        drawFrame(in: &context)
        let inner = CGRect(x: 8, y: 8, width: 123, height: 173)
        let innerPath = Path(roundedRect: inner, cornerRadius: 11)
        context.fill(innerPath, with: .linearGradient(
            Gradient(colors: [
                Color(red: 0.10, green: 0.17, blue: 0.33),
                Color(red: 0.05, green: 0.10, blue: 0.22),
            ]),
            startPoint: inner.origin,
            endPoint: CGPoint(x: inner.maxX, y: inner.maxY)))
        var lattice = context
        lattice.clip(to: innerPath)
        let step: CGFloat = 14
        var y = inner.minY - step
        var rowToggle = false
        while y < inner.maxY + step {
            var x = inner.minX - step + (rowToggle ? step / 2 : 0)
            while x < inner.maxX + step {
                var diamond = Path()
                diamond.move(to: CGPoint(x: x, y: y - 4.2))
                diamond.addLine(to: CGPoint(x: x + 3, y: y))
                diamond.addLine(to: CGPoint(x: x, y: y + 4.2))
                diamond.addLine(to: CGPoint(x: x - 3, y: y))
                diamond.closeSubpath()
                lattice.fill(diamond, with: .color(amber.opacity(0.42)))
                x += step
            }
            y += step / 2
            rowToggle.toggle()
        }
        context.stroke(
            Path(roundedRect: inner.insetBy(dx: 2.5, dy: 2.5), cornerRadius: 9),
            with: .color(amber.opacity(0.85)), lineWidth: 1.4)
        // Center medallion: the large diamond pip in gold.
        if let d = CardArt.largeSuit[.diamonds] {
            var medallion = context
            medallion.translateBy(x: 69 - 22, y: 95 - 65.5)  // recenters the pip's own coords
            fill(d, with: .color(amber.opacity(0.9)), in: &medallion)
        }
    }

    // MARK: Shared helpers

    private static func fill(_ d: String, with shading: GraphicsContext.Shading, in context: inout GraphicsContext) {
        context.fill(PathCache.path(for: d), with: shading)
    }

    /// Resolves the SVG fill tokens (classes, gradient ids, hex literals).
    private static func shading(for token: String, d: String) -> GraphicsContext.Shading {
        func gradient(_ from: String, _ to: String) -> GraphicsContext.Shading {
            let bounds = PathCache.path(for: d).boundingRect
            return .linearGradient(
                Gradient(colors: [Color(hex: from), Color(hex: to)]),
                startPoint: CGPoint(x: bounds.minX, y: bounds.maxY),
                endPoint: CGPoint(x: bounds.maxX, y: bounds.minY))
        }
        switch token {
        case "face": return gradient("#ffd8c1", "#ffeded")
        case "crown1": return gradient("#f0a700", "#ffed00")
        case "crown2": return gradient("#f0eb00", "#ffff00")
        case "redUniform": return gradient("#c10000", "#ff433e")
        case "navyUniform": return gradient("#000060", "#0000c0")
        case "yellowStripe": return gradient("#f0eb00", "#ffff00")
        case "greenTie": return gradient("#008200", "#00d000")
        case "redTie": return gradient("#b20000", "#d00000")
        case "blueEyes": return .color(Color(hex: "#1e2ecf"))
        case "brownEyes": return .color(Color(hex: "#b67870"))
        case "blackHair", "blackMoustache", "blackBeard": return .color(.black)
        case "blackishHair": return .color(Color(hex: "#444433"))
        case "brownHair", "brownMoustache", "brownBeard": return .color(Color(hex: "#6d2b00"))
        case "linearGradient30467": return .color(Color(hex: "#801818"))  // mouth (gradient absent in source)
        default: return .color(Color(hex: token))
        }
    }
}

/// Parsed-path cache: SVG data strings → SwiftUI paths, parsed once.
@MainActor
private enum PathCache {
    private static var cache: [String: Path] = [:]

    // Canvas draws its symbols on the main actor; assumeIsolated keeps the
    // cache lock-free while staying strict-concurrency clean.
    nonisolated static func path(for d: String) -> Path {
        MainActor.assumeIsolated {
            if let cached = cache[d] { return cached }
            let parsed = SVGPath.path(d)
            cache[d] = parsed
            return parsed
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0)
    }
}

#Preview("Faces") {
    let deck = Card.fullDeck()
    ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
            ForEach([1, 6, 9, 10, 11, 12, 13, 25, 30, 36, 49, 104], id: \.self) { id in
                CardView(card: deck[id])
            }
            CardBackView()
        }
        .padding()
    }
    .background(Color(red: 0.05, green: 0.2, blue: 0.12))
}
