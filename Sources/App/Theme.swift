import SwiftUI
import UIKit

/// Design language: dark felt table with depth, amber accent matching the
/// card frames, glassy overlays, SF typography.
enum Theme {
    static let accent = Color(red: 0xC7 / 255.0, green: 0x89 / 255.0, blue: 0x1F / 255.0)
    static let feltTop = Color(red: 0.075, green: 0.23, blue: 0.16)
    static let feltBottom = Color(red: 0.03, green: 0.11, blue: 0.08)
    static let feltDeep = Color(red: 0.02, green: 0.07, blue: 0.05)

    static var felt: some View {
        RadialGradient(
            colors: [feltTop, feltBottom, feltDeep],
            center: .center, startRadius: 40, endRadius: 560)
        .ignoresSafeArea()
    }

    static func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func action() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

extension Animation {
    /// Fast spring used for card travel; falls back to a crossfade-friendly
    /// ease when Reduce Motion is on (callers pair with opacity transitions).
    static let cardSpring = Animation.spring(response: 0.34, dampingFraction: 0.82)
}
