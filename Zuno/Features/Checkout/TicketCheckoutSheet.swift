import SwiftUI

/// Paid ticketing: choose tiers and quantities, review the order, pay with PayHere and
/// receive tickets only after the server verifies the payment.
struct TicketCheckoutSheet: View {
    let detail: EventDetail
    let onComplete: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var quantities: [UUID: Int] = [:]
    @State private var phone = ""
    @State private var answers: [UUID: AnswerValue] = [:]
    @State private var payment = PaymentFlowModel()
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    EventMiniHeader(event: detail.summary)
                    switch payment.phase {
                    case .idle, .creating, .awaitingPayment:
                        selection
                    default:
                        PaymentStatusView(
                            model: payment,
                            successTitle: Text("Tickets confirmed"),
                            successMessage: Text("Your tickets are in the Tickets tab and available offline.")
                        ) { payment.reset() }
                    }
                }
                .padding(20)
                .readableWidth()
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .background(ZunoColor.background)
            .navigationTitle(Text("Tickets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                }
            }
        }
        .paymentFlow(payment)
        .presentationDetents([.large])
        .presentationCornerRadius(ZunoMetrics.sheetRadius)
        .onAppear {
            phone = session.profile?.phone ?? ""
            if let first = detail.tiers.first(where: { $0.isPurchasable(now: environment.now) }), quantities.isEmpty {
                quantities[first.id] = 1
            }
        }
        .zunoContainer("checkout.sheet")
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: Text("Choose tickets"))
                ForEach(detail.tiers) { tier in
                    TierStepperRow(tier: tier, quantity: binding(for: tier), now: environment.now)
                }
            }
            if !detail.questions.isEmpty {
                QuestionsForm(questions: detail.questions, answers: $answers, missing: [])
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: Text("Mobile number"))
                TextField(text: $phone, prompt: Text("077 123 4567")) { Text("Mobile number") }
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                    .accessibilityIdentifier("checkout.phone")
                Text("PayHere sends your receipt to this number.").font(.footnote).foregroundStyle(.zunoSecondary)
            }
            if let summary = previewSummary {
                OrderSummaryCard(summary: summary)
            }
            if let message = validationMessage ?? payment.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .systemRed))
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch payment.phase {
        case .idle, .creating, .awaitingPayment:
            BottomActionBar {
                Button {
                    Task { await pay() }
                } label: {
                    if let summary = previewSummary {
                        Text("Pay \(ZunoFormat.currency(summary.total)) with PayHere")
                    } else {
                        Text("Select tickets")
                    }
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: payment.phase == .creating))
                .disabled(previewSummary == nil || payment.isBusy)
                .accessibilityIdentifier("checkout.pay")
                Text("Payments are processed by PayHere. Tickets are issued after the payment is confirmed.")
                    .font(.caption2).foregroundStyle(.zunoTertiary).multilineTextAlignment(.center)
            }
        case .succeeded:
            BottomActionBar {
                Button("View tickets") {
                    onComplete()
                    dismiss()
                    router.open(.ticket(detail.id), in: .tickets)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
                .accessibilityIdentifier("checkout.viewTickets")
            }
        default:
            EmptyView()
        }
    }

    private func binding(for tier: TicketTier) -> Binding<Int> {
        Binding { quantities[tier.id] ?? 0 } set: { quantities[tier.id] = $0 }
    }

    private var previewSummary: OrderSummary? {
        let lines = detail.tiers.compactMap { tier -> OrderPricing.Line? in
            guard let quantity = quantities[tier.id], quantity > 0 else { return nil }
            return OrderPricing.Line(tier: tier, quantity: quantity)
        }
        return try? OrderPricing.summarize(lines, commissionBps: CommissionPolicy.defaultBasisPoints, now: environment.now)
    }

    private func pay() async {
        validationMessage = nil
        guard let normalized = SriLankaLocations.normalizedMobile(phone) else {
            validationMessage = String(localized: "Enter a Sri Lankan mobile number, e.g. 077 123 4567.")
            return
        }
        let missing = AnswerValidation.missingRequired(questions: detail.questions, answers: answers)
        guard missing.isEmpty else {
            validationMessage = ZunoError.answersInvalid.errorDescription
            return
        }
        let items = quantities.filter { $0.value > 0 }.map { CheckoutItem(tierID: $0.key, quantity: $0.value) }
        let payload = detail.questions.compactMap { question in answers[question.id].map { RegistrationAnswer(questionID: question.id, value: $0) } }
        await payment.start(purpose: .tickets(eventID: detail.id, items: items, answers: payload), phone: normalized, environment: environment)
    }
}

struct TierStepperRow: View {
    let tier: TicketTier
    @Binding var quantity: Int
    let now: Date

    var body: some View {
        let purchasable = tier.isPurchasable(now: now)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tier.name).font(.body.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text(ZunoFormat.currency(tier.price)).font(.subheadline.monospacedDigit()).foregroundStyle(.zunoSecondary)
                if !purchasable {
                    Text(tier.remaining <= 0 ? "Sold out" : "Not on sale").font(.caption.weight(.semibold)).foregroundStyle(.zunoTertiary)
                } else if case .limited(let remaining) = Availability.evaluate(remaining: tier.remaining, capacity: tier.quantity) {
                    Text("Only \(remaining) left").font(.caption.weight(.semibold)).foregroundStyle(.zunoAmber)
                }
            }
            Spacer()
            HStack(spacing: 0) {
                Button {
                    quantity = max(quantity - 1, 0)
                } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                }
                .disabled(quantity == 0)
                .accessibilityLabel(Text("Remove one \(tier.name) ticket"))
                Text("\(quantity)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 28)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text("\(tier.name): ^[\(quantity) ticket](inflect: true)"))
                Button {
                    quantity = min(quantity + 1, min(tier.maxPerOrder, tier.remaining))
                } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .disabled(!purchasable || quantity >= min(tier.maxPerOrder, tier.remaining))
                .accessibilityLabel(Text("Add one \(tier.name) ticket"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.zunoPrimary)
            .background(Capsule().fill(ZunoColor.surfaceRaised))
            .sensoryFeedback(.selection, trigger: quantity)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZunoColor.surface))
        .opacity(purchasable ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkout.tier")
    }
}

struct OrderSummaryCard: View {
    let summary: OrderSummary

    var body: some View {
        SurfaceCard {
            Text("Order summary").font(.headline).foregroundStyle(.zunoPrimary)
            ForEach(summary.lines) { line in
                DetailLine(title: Text("\(line.quantity) × \(line.label)"), value: ZunoFormat.currency(line.amount))
            }
            Divider().overlay(ZunoColor.divider)
            DetailLine(title: Text("Total"), value: ZunoFormat.currency(summary.total), emphasized: true)
            Text("Prices include all fees. Zuno's platform commission is paid by the organizer.")
                .font(.caption).foregroundStyle(.zunoTertiary)
        }
        .accessibilityIdentifier("checkout.summary")
    }
}
