import SwiftUI
import UIKit

/// Design language: dark felt table with depth, amber accent matching the
/// card frames, glassy overlays, SF typography.
enum Theme {
    static let accent = Color(red: 0xC7 / 255.0, green: 0x89 / 255.0, blue: 0x1F / 255.0)
    /// Lock color for a single card reserved for the table melds — clearly
    /// apart from the green series lock and the amber selection.
    static let placeableLock = Color(red: 0.25, green: 0.68, blue: 0.90)

    // The app is forced dark at the root (no theme variants), so the dark
    // tuple is what ships; the light tuple only remains as a fallback.
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let (r, g, b) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }

    static let feltTop = adaptive(dark: (0.075, 0.23, 0.16), light: (0.33, 0.58, 0.42))
    static let feltBottom = adaptive(dark: (0.03, 0.11, 0.08), light: (0.22, 0.44, 0.31))
    static let feltDeep = adaptive(dark: (0.02, 0.07, 0.05), light: (0.16, 0.35, 0.24))

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
