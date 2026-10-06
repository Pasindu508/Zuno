import SwiftUI

/// The large white capsule from the reference ("Buy ticket"): white fill, dark text.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    var compact = false
    var isLoading = false
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = ZunoMetrics.primaryButtonHeight
    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            configuration.label
                .font(.system(compact ? .body : .title3, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView()
                    .tint(ZunoColor.onSelectedFill)
            }
        }
        // Disabled stays solid (charcoal) so content never shows through the button.
        .foregroundStyle(isEnabled ? ZunoColor.onSelectedFill : ZunoColor.textSecondary)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: compact ? compactHeight : height)
        .background(
            Capsule().fill(isEnabled ? ZunoColor.selectedFill : ZunoColor.surfaceRaised)
        )
        .contentShape(.capsule)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Charcoal capsule for secondary actions on solid surfaces.
struct SecondaryCapsuleButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(destructive ? Color(uiColor: .systemRed) : ZunoColor.textPrimary)
            .opacity(isEnabled ? 1 : 0.45)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(configuration.isPressed ? ZunoColor.surfaceRaised : ZunoColor.surface))
            .contentShape(.capsule)
    }
}

/// A pinned bottom action area that respects the safe area and fades content under it.
struct BottomActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: ZunoMetrics.maxReadableWidth + 32)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                stops: [.init(color: ZunoColor.background.opacity(0), location: 0), .init(color: ZunoColor.background, location: 0.35)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

/// Section heading in SF Pro Display semibold with an optional trailing action.
struct SectionHeader: View {
    let title: Text
    var actionTitle: Text?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title
                .font(.title3.weight(.semibold))
                .foregroundStyle(.zunoPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(action: action) { actionTitle }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.zunoSecondary)
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Selectable capsule used inside filter and preference sheets.
struct SelectableChip: View {
    let title: Text
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.subheadline)
                }
                title.font(.subheadline.weight(isSelected ? .semibold : .regular))
                if isSelected {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? ZunoColor.onSelectedFill : ZunoColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(isSelected ? ZunoColor.selectedFill : ZunoColor.surface))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Solid surface card container for grouped content (settings rows, summaries).
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
    }
}

extension View {
    /// Native dark sheet styling: glass on partial detents, near-black when full height.
    func zunoSheetChrome(fullHeight: Bool = false) -> some View {
        self
            .presentationCornerRadius(ZunoMetrics.sheetRadius)
            .presentationDragIndicator(.visible)
            .presentationBackground(fullHeight ? AnyShapeStyle(ZunoColor.background) : AnyShapeStyle(.regularMaterial))
    }

    /// Constrains reading width on iPad / landscape while staying full width on phones.
    func readableWidth(_ max: CGFloat = ZunoMetrics.maxReadableWidth) -> some View {
        frame(maxWidth: max).frame(maxWidth: .infinity)
    }
}
