import SwiftUI
import UIKit

/// Typography roles.
/// - Sansita One: event titles and selected editorial display headings only.
/// - SF Pro (system): headings, body, controls, navigation, metadata.
/// - SF Mono: ticket codes, references, transaction identifiers and compact dates.
enum ZunoFont {
    static let displayPostScriptName = "SansitaOne-Regular"

    /// `true` when the bundled Sansita One registered through `UIAppFonts` loaded.
    static let isDisplayFontAvailable: Bool = UIFont(name: displayPostScriptName, size: 17) != nil

    /// Raw display font scaled with Dynamic Type relative to `style`.
    /// Falls back to a heavy system serif if the font failed to load.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        if isDisplayFontAvailable {
            return .custom(displayPostScriptName, size: size, relativeTo: style)
        }
        return .system(style, design: .serif, weight: .black).italic()
    }

    /// Accessible fallback used at accessibility text sizes, where the condensed
    /// display face gets hard to read. Keeps the hierarchy with a heavy system serif.
    static func accessibleDisplay(relativeTo style: Font.TextStyle) -> Font {
        .system(style, design: .serif, weight: .bold)
    }

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

/// Display styles measured from the reference (iPhone 6.1" at 1x).
enum DisplayStyle {
    case hero          // onboarding / auth wordmark
    case detailTitle   // event detail title (≈30 pt)
    case cardTitle     // event card title (≈24 pt)
    case section       // editorial section heading
    case compact       // ticket rows, calendar agenda titles

    var size: CGFloat {
        switch self {
        case .hero: 44
        case .detailTitle: 30
        case .cardTitle: 24
        case .section: 22
        case .compact: 19
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .hero: .largeTitle
        case .detailTitle: .title
        case .cardTitle: .title2
        case .section: .title3
        case .compact: .headline
        }
    }
}

private struct DisplayTextModifier: ViewModifier {
    let style: DisplayStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content
            .font(useFallback ? ZunoFont.accessibleDisplay(relativeTo: style.textStyle)
                              : ZunoFont.display(style.size, relativeTo: style.textStyle))
            .lineSpacing(useFallback ? 2 : -1)
            .tracking(useFallback ? 0 : 0.2)
    }

    private var useFallback: Bool {
        dynamicTypeSize >= .accessibility2
    }
}

extension View {
    /// Applies the Sansita One editorial treatment (with the accessibility fallback).
    func zunoDisplay(_ style: DisplayStyle) -> some View {
        modifier(DisplayTextModifier(style: style))
    }
}
