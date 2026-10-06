import SwiftUI
import UIKit

/// The four reference colors. Every other brand color is derived from these with opacity.
enum ZunoPalette {
    static let nearBlack = UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1) // #111110
    static let charcoal = UIColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x21 / 255, alpha: 1)  // #232321
    static let amber = UIColor(red: 0xED / 255, green: 0xA7 / 255, blue: 0x1A / 255, alpha: 1)     // #EDA71A
    static let white = UIColor.white                                                              // #FFFFFF

    /// Light appearance: a warm off-white page derived from white with 4 % near-black.
    static let lightPage = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF4 / 255, alpha: 1)
}

/// Semantic color tokens. Dark is the primary identity; the light appearance swaps roles
/// deliberately (it is not an automatic inversion) and keeps the same four hues.
enum ZunoColor {
    /// `#111110` application background.
    static let background = dynamic(dark: ZunoPalette.nearBlack, light: ZunoPalette.lightPage)
    /// `#232321` elevated surface for cards, panels, fields and capsules.
    static let surface = dynamic(dark: ZunoPalette.charcoal, light: ZunoPalette.white)
    /// Slightly lifted surface for pressed rows and nested panels.
    static let surfaceRaised = dynamic(
        dark: ZunoPalette.white.withAlphaComponent(0.09).composited(over: ZunoPalette.charcoal),
        light: ZunoPalette.nearBlack.withAlphaComponent(0.05).composited(over: ZunoPalette.white)
    )
    /// `#EDA71A` accent: location pins, unread indicators, low-availability warnings.
    static let amber = Color(uiColor: ZunoPalette.amber)

    /// Primary text and icons.
    static let textPrimary = dynamic(dark: ZunoPalette.white, light: ZunoPalette.nearBlack)
    /// Secondary text (metadata, captions). Raised under Increase Contrast.
    static let textSecondary = dynamicOpacity(normal: 0.62, highContrast: 0.82)
    /// Tertiary text, placeholders and inactive tab items.
    static let textTertiary = dynamicOpacity(normal: 0.44, highContrast: 0.68)
    /// Disabled controls.
    static let disabled = dynamicOpacity(normal: 0.30, highContrast: 0.50)
    /// Hairline dividers.
    static let divider = dynamicOpacity(normal: 0.09, highContrast: 0.24)

    /// Selected capsule / primary button fill (white in dark, near-black in light).
    static let selectedFill = dynamic(dark: ZunoPalette.white, light: ZunoPalette.nearBlack)
    /// Content drawn on `selectedFill`.
    static let onSelectedFill = dynamic(dark: ZunoPalette.nearBlack, light: ZunoPalette.white)

    /// Glass tint for floating controls; keeps native glass close to the reference charcoal.
    static let glassTint = dynamic(
        dark: ZunoPalette.charcoal.withAlphaComponent(0.55),
        light: ZunoPalette.white.withAlphaComponent(0.55)
    )

    /// The QR surface is always white so scanners read it in any appearance.
    static let qrSurface = Color.white

    // MARK: - Helpers

    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? light : dark
        })
    }

    private static func dynamicOpacity(normal: CGFloat, highContrast: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let alpha = traits.accessibilityContrast == .high ? highContrast : normal
            let base = traits.userInterfaceStyle == .light ? ZunoPalette.nearBlack : ZunoPalette.white
            return base.withAlphaComponent(alpha)
        })
    }
}

extension UIColor {
    /// Flattens a translucent color over an opaque one so solid surfaces stay solid.
    func composited(over base: UIColor) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        base.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 * a1 + r2 * (1 - a1),
            green: g1 * a1 + g2 * (1 - a1),
            blue: b1 * a1 + b2 * (1 - a1),
            alpha: 1
        )
    }
}

extension ShapeStyle where Self == Color {
    static var zunoBackground: Color { ZunoColor.background }
    static var zunoSurface: Color { ZunoColor.surface }
    static var zunoAmber: Color { ZunoColor.amber }
    static var zunoPrimary: Color { ZunoColor.textPrimary }
    static var zunoSecondary: Color { ZunoColor.textSecondary }
    static var zunoTertiary: Color { ZunoColor.textTertiary }
}
