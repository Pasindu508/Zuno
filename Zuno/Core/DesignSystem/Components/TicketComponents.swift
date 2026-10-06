import CoreImage.CIFilterBuiltins
import SwiftUI

/// White QR surface: always black-on-white with a quiet zone so any scanner reads it.
struct QRSurface: View {
    let payload: String
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let image = Self.render(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.black)
            }
        }
        .frame(width: size, height: size)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(ZunoColor.qrSurface))
        .accessibilityLabel(Text("Ticket QR code"))
        .accessibilityIdentifier("ticket.qr")
    }

    static func render(_ payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Dark ticket row: artwork, Sansita title, date/venue, tier and status.
struct TicketCard: View {
    let ticket: Ticket

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(reference: ticket.event.cover, fallbackSymbol: EventCategory.symbol(for: ticket.event.categoryID))
                .frame(width: 84, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text(ticket.event.title)
                    .zunoDisplay(.compact)
                    .foregroundStyle(.zunoPrimary)
                    .lineLimit(2)
                EventMetadataRow(systemImage: "calendar", text: ZunoFormat.eventDateLine(start: ticket.event.startsAt, end: ticket.event.endsAt))
                EventMetadataRow(systemImage: "mappin.and.ellipse", text: ticket.event.venueName ?? String(localized: "Online"))
                HStack(spacing: 8) {
                    Text(ticket.tierName)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.zunoPrimary)
                    TicketStatusBadge(status: ticket.status)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.zunoTertiary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
        .accessibilityElement(children: .combine)
    }
}

struct TicketStatusBadge: View {
    let status: TicketStatus

    var body: some View {
        Label(status.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var symbol: String {
        switch status {
        case .valid: "checkmark.circle"
        case .checkedIn: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        case .refunded: "arrow.uturn.backward.circle"
        }
    }

    private var color: Color {
        switch status {
        case .valid: ZunoColor.textPrimary
        case .checkedIn: ZunoColor.amber
        case .cancelled, .refunded: ZunoColor.textSecondary
        }
    }
}

/// Wallet ledger row with signed LKR amount and status.
struct WalletRow: View {
    let transaction: WalletTransaction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transaction.type.symbolName)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.zunoPrimary)
                .frame(width: 42, height: 42)
                .background(Circle().fill(ZunoColor.surfaceRaised))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.type.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.zunoPrimary)
                Text(transaction.description)
                    .font(.footnote)
                    .foregroundStyle(.zunoSecondary)
                    .lineLimit(1)
                Text(ZunoFormat.compactTimestamp(transaction.createdAt))
                    .font(ZunoFont.mono(.caption2))
                    .foregroundStyle(.zunoTertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ZunoFormat.currency(transaction.amount, showSign: true))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(transaction.status == .failed ? ZunoColor.textTertiary : ZunoColor.textPrimary)
                    .strikethrough(transaction.status == .failed)
                if transaction.status != .posted {
                    Text(transaction.status.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(transaction.status == .pending ? ZunoColor.amber : Color(uiColor: .systemRed))
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
