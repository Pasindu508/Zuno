import SwiftUI

/// Full-width event artwork with floating glass controls: back (top-left), date pill
/// (bottom-left) and favorite + share (bottom-right) straddling the artwork's lower edge.
struct DetailArtworkHeader: View {
    let event: EventSummary
    let isSaved: Bool
    let pillText: String
    let height: CGFloat
    var showsBackButton = true
    let shareURL: URL
    let onBack: () -> Void
    let onToggleSave: () -> Void

    @Namespace private var controlsNamespace
    private let straddle: CGFloat = 24

    var body: some View {
        ArtworkImage(reference: event.cover, accessibilityLabel: event.coverAlt, fallbackSymbol: EventCategory.symbol(for: event.categoryID), settles: true)
            .frame(height: height)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: ZunoMetrics.detailArtworkRadius,
                bottomLeadingRadius: 6,
                bottomTrailingRadius: 6,
                topTrailingRadius: ZunoMetrics.detailArtworkRadius,
                style: .continuous
            ))
            .padding(.horizontal, ZunoMetrics.detailArtworkInset)
            .overlay(alignment: .topLeading) {
                if showsBackButton {
                    FloatingGlassIconButton(systemName: "arrow.left", accessibilityLabel: Text("Back"), placement: .onMedia,
                                            accessibilityIdentifier: "detail.back", action: onBack)
                        .padding(.leading, ZunoMetrics.margin)
                        .padding(.top, 10)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .center) {
                    DatePill(text: Text(pillText))
                        .accessibilityIdentifier("detail.datePill")
                    Spacer(minLength: 12)
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            FavoriteGlassButton(isSaved: isSaved, placement: .onMedia, action: onToggleSave)
                                .glassEffectID("favorite", in: controlsNamespace)
                            ShareGlassButton(url: shareURL, title: event.title)
                                .glassEffectID("share", in: controlsNamespace)
                        }
                    }
                }
                .padding(.horizontal, ZunoMetrics.margin)
                .offset(y: straddle)
            }
            .padding(.bottom, straddle)
    }
}

struct ShareGlassButton: View {
    let url: URL
    let title: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = ZunoMetrics.floatingControlSize

    var body: some View {
        ShareLink(item: url, subject: Text(title), message: Text("\(title) on Zuno")) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: min(max(size, 44), 68), height: min(max(size, 44), 68))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .zunoGlass(in: .circle, placement: .onMedia)
        .accessibilityLabel(Text("Share event"))
        .accessibilityIdentifier("detail.share")
    }
}
