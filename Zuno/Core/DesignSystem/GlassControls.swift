import SwiftUI

/// Where a glass control sits. Controls over artwork always use a dark tint and white
/// glyphs; controls on the page follow the appearance.
enum GlassPlacement {
    case onPage
    case onMedia

    var tint: Color {
        switch self {
        case .onPage: ZunoColor.glassTint
        case .onMedia: Color(uiColor: ZunoPalette.nearBlack.withAlphaComponent(0.38))
        }
    }

    var foreground: Color {
        switch self {
        case .onPage: ZunoColor.textPrimary
        case .onMedia: .white
        }
    }
}

/// Applies native Liquid Glass to a functional control, with a solid charcoal fallback when
/// Reduce Transparency is on. Glass is switched by value (`.identity`) so identity is stable.
struct ZunoGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var placement: GlassPlacement = .onPage
    var interactive: Bool = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(reduceTransparency ? solidFallback : Color.clear)
            }
            .glassEffect(glass, in: shape)
    }

    private var solidFallback: Color {
        placement == .onMedia ? Color(uiColor: ZunoPalette.charcoal) : ZunoColor.surface
    }

    private var glass: Glass {
        guard !reduceTransparency else { return .identity }
        let tinted = Glass.regular.tint(placement.tint)
        return interactive ? tinted.interactive() : tinted
    }
}

extension View {
    func zunoGlass<S: Shape>(in shape: S, placement: GlassPlacement = .onPage, interactive: Bool = true) -> some View {
        modifier(ZunoGlassModifier(shape: shape, placement: placement, interactive: interactive))
    }
}

/// Circular floating control (back, favorite, share, notifications, filters).
struct FloatingGlassIconButton: View {
    let systemName: String
    let accessibilityLabel: Text
    var placement: GlassPlacement = .onPage
    var accessibilityIdentifier: String?
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = ZunoMetrics.floatingControlSize

    init(
        systemName: String,
        accessibilityLabel: Text,
        placement: GlassPlacement = .onPage,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.placement = placement
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(placement.foreground)
                .frame(width: clampedSize, height: clampedSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .zunoGlass(in: .circle, placement: placement)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? systemName)
    }

    private var clampedSize: CGFloat { min(max(size, ZunoMetrics.minimumTouchTarget), 68) }
}

/// Favorite control whose symbol replaces smoothly and confirms with a success haptic.
struct FavoriteGlassButton: View {
    let isSaved: Bool
    var placement: GlassPlacement = .onMedia
    var compact = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var regularSize: CGFloat = ZunoMetrics.floatingControlSize
    @ScaledMetric(relativeTo: .body) private var compactSize: CGFloat = 38

    var body: some View {
        Button(action: action) {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: compact ? 16 : 19, weight: .regular))
                .foregroundStyle(isSaved ? ZunoColor.amber : placement.foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .zunoGlass(in: .circle, placement: placement)
        .sensoryFeedback(.success, trigger: isSaved) { _, new in new }
        .accessibilityLabel(isSaved ? Text("Remove from saved") : Text("Save event"))
        .accessibilityIdentifier("event.favorite")
    }

    private var side: CGFloat {
        compact ? min(max(compactSize, 36), 52) : min(max(regularSize, 44), 68)
    }
}

/// Glass date / availability pill shown over artwork ("Until 5 Nov").
struct DatePill: View {
    let text: Text
    var placement: GlassPlacement = .onMedia
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 48

    var body: some View {
        text
            .font(.callout)
            .foregroundStyle(placement.foreground)
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(minHeight: min(height, 64))
            .zunoGlass(in: .capsule, placement: placement, interactive: false)
            .accessibilityElement(children: .combine)
    }
}

/// Small glass label used on card artwork (price / availability).
struct ArtworkTag: View {
    let text: Text
    var emphasis: Color = .white

    var body: some View {
        text
            .font(.footnote.weight(.semibold))
            .foregroundStyle(emphasis)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .zunoGlass(in: .capsule, placement: .onMedia, interactive: false)
    }
}
