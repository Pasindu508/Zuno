import SwiftUI

/// Muted metadata line with an outline SF Symbol (venue, dates, organizer).
struct EventMetadataRow: View {
    let systemImage: String
    let text: String
    var emphasis: Color = ZunoColor.textSecondary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .light))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(emphasis)
    }
}

/// The reference card: large landscape artwork whose top corners are the card's corners,
/// a solid charcoal information panel, Sansita One title, one/two-line description and
/// restrained metadata.
struct EventCard: View {
    let event: EventSummary
    var now: Date = .now
    var titleLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkImage(reference: event.cover, fallbackSymbol: EventCategory.symbol(for: event.categoryID))
                .aspectRatio(ZunoMetrics.artworkAspectRatio, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    EventPriceTag(event: event)
                        .padding(12)
                }
            VStack(alignment: .leading, spacing: 9) {
                Text(event.title)
                    .zunoDisplay(.cardTitle)
                    .foregroundStyle(.zunoPrimary)
                    .lineLimit(titleLines)
                    .fixedSize(horizontal: false, vertical: true)
                if !event.summary.isEmpty {
                    Text(event.summary)
                        .font(.callout)
                        .foregroundStyle(ZunoColor.textPrimary.opacity(0.92))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { place; date }
                    VStack(alignment: .leading, spacing: 6) { place; date }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, ZunoMetrics.cardPadding)
            .padding(.top, 14)
            .padding(.bottom, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZunoColor.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous))
    }

    private var place: some View {
        EventMetadataRow(systemImage: event.format == .online ? "globe" : "mappin.and.ellipse", text: event.placeLine)
    }

    private var date: some View {
        EventMetadataRow(systemImage: "calendar", text: ZunoFormat.eventDateLine(start: event.startsAt, end: event.endsAt, now: now))
    }

    /// One VoiceOver sentence for the whole card.
    static func accessibilityDescription(_ event: EventSummary, isSaved: Bool, now: Date = .now) -> String {
        var parts = [event.title, event.summary, event.placeLine,
                     ZunoFormat.eventDateLine(start: event.startsAt, end: event.endsAt, now: now),
                     ZunoFormat.priceLabel(for: event)]
        switch event.availability {
        case .soldOut: parts.append(String(localized: "Sold out"))
        case .limited(let remaining): parts.append(String(AttributedString(localized: "^[\(remaining) place](inflect: true) left").characters))
        case .available: break
        }
        if isSaved { parts.append(String(localized: "Saved")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Price and availability as a small glass tag on the artwork.
struct EventPriceTag: View {
    let event: EventSummary

    var body: some View {
        switch event.availability {
        case .soldOut:
            ArtworkTag(text: Text("Sold out"))
        case .limited(let remaining):
            ArtworkTag(text: Text("\(ZunoFormat.priceLabel(for: event)) · \(remaining) left"), emphasis: ZunoColor.amber)
        case .available:
            ArtworkTag(text: Text(ZunoFormat.priceLabel(for: event)))
        }
    }
}

/// A card that navigates to the event and carries its own favorite control and zoom source.
struct EventCardLink: View {
    let event: EventSummary
    let isSaved: Bool
    let namespace: Namespace.ID
    var now: Date = .now
    let onToggleSave: () -> Void

    var body: some View {
        NavigationLink(value: AppRoute.event(event.id)) {
            EventCard(event: event, now: now)
        }
        .buttonStyle(CardPressStyle())
        .matchedTransitionSource(id: event.id, in: namespace) { source in
            source.clipShape(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous))
        }
        .overlay(alignment: .topTrailing) {
            FavoriteGlassButton(isSaved: isSaved, compact: true, action: onToggleSave)
                .padding(10)
                .accessibilityHidden(true) // exposed as a custom action on the card instead
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(EventCard.accessibilityDescription(event, isSaved: isSaved, now: now)))
        .accessibilityHint(Text("Opens event details"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isSaved ? Text("Remove from saved") : Text("Save event"), onToggleSave)
        .accessibilityIdentifier("event.card")
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}
