import Observation
import SwiftUI

@MainActor
@Observable
final class RegistrationModel {
    enum Phase {
        case loading
        case ready(FreeRegistrationQuote)
        case submitting(FreeRegistrationQuote)
        case confirmed(RegistrationConfirmation, Ticket?)
        case failed(Error)
    }

    var phase: Phase = .loading
    var answers: [UUID: AnswerValue] = [:]
    var inlineError: String?
    var successTrigger = false
    var errorTrigger = false
    /// One key per registration intent: retries reuse it so the server can't double-register.
    let idempotencyKey = IdempotencyKey.make(prefix: "reg")

    func loadQuote(eventID: UUID, environment: AppEnvironment) async {
        phase = .loading
        do {
            phase = .ready(try await environment.registrations.quoteFreeRegistration(eventID: eventID))
        } catch {
            phase = .failed(error)
        }
    }

    func missingAnswers(_ questions: [RegistrationQuestion]) -> [UUID] {
        AnswerValidation.missingRequired(questions: questions, answers: answers)
    }

    func confirm(detail: EventDetail, quote: FreeRegistrationQuote, environment: AppEnvironment) async {
        guard missingAnswers(detail.questions).isEmpty else {
            inlineError = ZunoError.answersInvalid.errorDescription
            errorTrigger.toggle()
            return
        }
        inlineError = nil
        phase = .submitting(quote)
        do {
            let payload = detail.questions.compactMap { question in
                answers[question.id].map { RegistrationAnswer(questionID: question.id, value: $0) }
            }
            let confirmation = try await environment.registrations.registerFree(
                eventID: detail.id, answers: payload, expectedFee: quote.fee, idempotencyKey: idempotencyKey
            )
            let tickets = (try? await environment.tickets.tickets()) ?? []
            let ticket = tickets.first { $0.id == confirmation.ticketID }
            phase = .confirmed(confirmation, ticket)
            successTrigger.toggle()
        } catch ZunoError.feeChanged {
            inlineError = ZunoError.feeChanged.errorDescription
            errorTrigger.toggle()
            await loadQuote(eventID: detail.id, environment: environment)
        } catch {
            inlineError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorTrigger.toggle()
            phase = .ready(quote)
        }
    }
}

/// Free registration: shows the monthly allowance, the exact wallet deduction when the
/// allowance is used up, the organizer's questions, then reveals the QR ticket.
struct RegistrationSheet: View {
    let detail: EventDetail
    let onComplete: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = RegistrationModel()
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    EventMiniHeader(event: detail.summary)
                    switch model.phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    case .failed(let error):
                        ErrorStateView(error: error) { Task { await model.loadQuote(eventID: detail.id, environment: environment) } }
                            .frame(minHeight: 260)
                    case .ready(let quote), .submitting(let quote):
                        AllowanceCard(quote: quote)
                        if let reason = quote.reason { blocked(reason) }
                        if quote.canRegister && !detail.questions.isEmpty {
                            QuestionsForm(questions: detail.questions, answers: $model.answers,
                                          missing: model.inlineError == nil ? [] : model.missingAnswers(detail.questions))
                        }
                    case .confirmed(let confirmation, let ticket):
                        confirmationView(confirmation, ticket: ticket)
                    }
                    if let error = model.inlineError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color(uiColor: .systemRed))
                            .accessibilityIdentifier("registration.error")
                    }
                }
                .padding(20)
                .readableWidth()
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .background(ZunoColor.background)
            .navigationTitle(Text("Register"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(ZunoMetrics.sheetRadius)
        .sensoryFeedback(.success, trigger: model.successTrigger)
        .sensoryFeedback(.error, trigger: model.errorTrigger)
        .task { await model.loadQuote(eventID: detail.id, environment: environment) }
        .zunoContainer("registration.sheet")
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch model.phase {
        case .ready(let quote), .submitting(let quote):
            if quote.canRegister {
                BottomActionBar {
                    Button {
                        Task { await model.confirm(detail: detail, quote: quote, environment: environment) }
                    } label: {
                        Text(quote.requiresWalletDeduction
                             ? "Confirm and pay \(ZunoFormat.currency(quote.fee))"
                             : String(localized: "Confirm registration"))
                    }
                    .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: isSubmitting))
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("registration.confirm")
                }
            }
        case .confirmed:
            BottomActionBar {
                Button("Done") {
                    onComplete()
                    dismiss()
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
                .accessibilityIdentifier("registration.done")
            }
        default:
            EmptyView()
        }
    }

    private var isSubmitting: Bool {
        if case .submitting = model.phase { return true }
        return false
    }

    @ViewBuilder
    private func blocked(_ reason: RegistrationBlockReason) -> some View {
        SurfaceCard {
            Label(reason.message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.zunoPrimary)
            switch reason {
            case .insufficientBalance:
                Button("Top up wallet") {
                    dismiss()
                    router.open(.wallet)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
            case .identityRequired:
                Button("Set up identity") {
                    dismiss()
                    router.open(.identity)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
            default:
                EmptyView()
            }
        }
        .zunoContainer("registration.blocked")
    }

    private func confirmationView(_ confirmation: RegistrationConfirmation, ticket: Ticket?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.zunoAmber)
                .symbolEffect(.bounce, value: revealed)
            Text("You're registered")
                .zunoDisplay(.section)
                .foregroundStyle(.zunoPrimary)
            if let ticket {
                QRSurface(payload: ticket.qrPayload, size: 200)
                    .scaleEffect(revealed || reduceMotion ? 1 : 0.86)
                    .opacity(revealed ? 1 : 0)
                Text(ticket.code)
                    .font(ZunoFont.mono(.title3, weight: .semibold))
                    .foregroundStyle(.zunoPrimary)
                    .accessibilityLabel(Text("Ticket code \(ticket.code)"))
            }
            VStack(spacing: 6) {
                Text("Reference \(confirmation.reference)").font(ZunoFont.mono(.footnote)).foregroundStyle(.zunoSecondary)
                if confirmation.fee.minorUnits > 0 {
                    Text("\(ZunoFormat.currency(confirmation.fee)) deducted · balance \(ZunoFormat.currency(confirmation.walletBalance))")
                        .font(.footnote).foregroundStyle(.zunoSecondary)
                } else {
                    Text("^[\(confirmation.allowanceRemaining) free registration](inflect: true) left this month")
                        .font(.footnote).foregroundStyle(.zunoSecondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(ZunoMotion.adaptive(ZunoMotion.reveal, reduceMotion: reduceMotion)) { revealed = true }
        }
        .zunoContainer("registration.confirmed")
    }
}

/// Allowance meter + exact deduction disclosure.
struct AllowanceCard: View {
    let quote: FreeRegistrationQuote

    var body: some View {
        SurfaceCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly free registrations")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.zunoPrimary)
                Spacer()
                Text("\(quote.allowanceRemaining) of \(quote.allowanceLimit) left")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(quote.allowanceRemaining <= 2 ? ZunoColor.amber : ZunoColor.textSecondary)
            }
            AllowanceMeter(used: quote.allowanceUsed, limit: quote.allowanceLimit)
            if quote.requiresWalletDeduction {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You've used this month's 15 free registrations.")
                        .font(.callout)
                        .foregroundStyle(.zunoPrimary)
                    DetailLine(title: Text("Deducted from wallet"), value: ZunoFormat.currency(quote.fee), emphasized: true)
                    DetailLine(title: Text("Wallet balance"), value: ZunoFormat.currency(quote.walletBalance))
                    DetailLine(title: Text("Balance after"), value: ZunoFormat.currency(quote.balanceAfter))
                }
                .accessibilityIdentifier("registration.deduction")
            } else {
                Text("This registration is included in your allowance — nothing is charged.")
                    .font(.footnote)
                    .foregroundStyle(.zunoSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("registration.allowance")
    }
}

struct AllowanceMeter: View {
    let used: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(limit, 1), id: \.self) { index in
                Capsule()
                    .fill(index < used ? ZunoColor.textTertiary : ZunoColor.selectedFill)
                    .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(max(limit - used, 0)) of \(limit) free registrations left"))
    }
}

struct DetailLine: View {
    let title: Text
    let value: String
    var emphasized = false

    var body: some View {
        HStack {
            title.font(.subheadline).foregroundStyle(.zunoSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(emphasized ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(emphasized ? ZunoColor.amber : ZunoColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EventMiniHeader: View {
    let event: EventSummary
    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(reference: event.cover)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).zunoDisplay(.compact).foregroundStyle(.zunoPrimary).lineLimit(2)
                Text(ZunoFormat.eventDateLine(start: event.startsAt, end: event.endsAt))
                    .font(.footnote).foregroundStyle(.zunoSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Organizer questions with required-field validation.
struct QuestionsForm: View {
    let questions: [RegistrationQuestion]
    @Binding var answers: [UUID: AnswerValue]
    var missing: [UUID]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: Text("Questions from the organizer"))
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(question.prompt).font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                        if question.required {
                            Text("Required").font(.caption).foregroundStyle(missing.contains(question.id) ? ZunoColor.amber : ZunoColor.textTertiary)
                        }
                    }
                    input(for: question)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func input(for question: RegistrationQuestion) -> some View {
        switch question.kind {
        case .shortText, .longText:
            TextField(text: textBinding(question.id), prompt: Text("Your answer"), axis: question.kind == .longText ? .vertical : .horizontal) {
                Text(question.prompt)
            }
            .lineLimit(question.kind == .longText ? 3...6 : 1...1)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
        case .singleChoice:
            FlowLayout(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    SelectableChip(title: Text(option), isSelected: choices(question.id).contains(option)) {
                        answers[question.id] = .choices([option])
                    }
                }
            }
        case .multiChoice:
            FlowLayout(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    SelectableChip(title: Text(option), isSelected: choices(question.id).contains(option)) {
                        var current = choices(question.id)
                        if let index = current.firstIndex(of: option) { current.remove(at: index) } else { current.append(option) }
                        answers[question.id] = .choices(current)
                    }
                }
            }
        case .yesNo:
            HStack(spacing: 8) {
                SelectableChip(title: Text("Yes"), isSelected: answers[question.id] == .bool(true)) { answers[question.id] = .bool(true) }
                SelectableChip(title: Text("No"), isSelected: answers[question.id] == .bool(false)) { answers[question.id] = .bool(false) }
            }
        }
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding {
            if case .text(let value)? = answers[id] { return value }
            return ""
        } set: { answers[id] = .text($0) }
    }

    private func choices(_ id: UUID) -> [String] {
        if case .choices(let values)? = answers[id] { return values }
        return []
    }
}
