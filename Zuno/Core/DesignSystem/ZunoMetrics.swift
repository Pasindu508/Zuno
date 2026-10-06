import SwiftUI

/// Layout tokens measured from the reference screens (see docs/IMPLEMENTATION_CHECKLIST.md).
/// Control sizes scale with Dynamic Type through `@ScaledMetric` in the components.
enum ZunoMetrics {
    static let margin: CGFloat = 18
    static let controlHeight: CGFloat = 50
    static let controlSpacing: CGFloat = 10
    static let headerToSearch: CGFloat = 16
    static let searchToChips: CGFloat = 22
    static let chipsToFeed: CGFloat = 16
    static let cardSpacing: CGFloat = 14
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let artworkAspectRatio: CGFloat = 1.69
    static let detailArtworkInset: CGFloat = 8
    static let detailArtworkRadius: CGFloat = 30
    static let floatingControlSize: CGFloat = 50
    static let primaryButtonHeight: CGFloat = 58
    static let sheetRadius: CGFloat = 28
    static let maxReadableWidth: CGFloat = 640
    static let minimumTouchTarget: CGFloat = 44
}

/// Motion tokens. Every custom animation goes through these so Reduce Motion is honoured.
enum ZunoMotion {
    static let selection = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let reveal = Animation.spring(response: 0.45, dampingFraction: 0.78)
    static let settle = Animation.easeOut(duration: 0.9)
    static let fade = Animation.easeInOut(duration: 0.2)

    /// Returns the given animation, or a short cross-fade when Reduce Motion is on.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension View {
    /// Identifies a screen or region for UI tests without overriding the identifiers of the
    /// controls inside it (SwiftUI propagates identifiers set on plain containers to children).
    func zunoContainer(_ identifier: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}
