import Observation
import SwiftUI

@MainActor
@Observable
final class WalletModel {
    var summary: Loadable<WalletSummary> = .idle
    var transactions: [WalletTransaction] = []

    func load(environment: AppEnvironment) async {
        if summary.value == nil { summary = .loading }
        do {
            async let summaryTask = environment.wallet.summary()
            async let transactionsTask = environment.wallet.transactions()
            let (loadedSummary, loadedTransactions) = try await (summaryTask, transactionsTask)
            summary = .loaded(loadedSummary)
            transactions = loadedTransactions
        } catch {
            if summary.value == nil { summary = .failed(error) }
        }
    }

    var groupedTransactions: [(month: String, items: [WalletTransaction])] {
        let grouped = Dictionary(grouping: transactions) { ZunoFormat.monthYear($0.createdAt) }
        return grouped.map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast) }
    }
}

struct WalletView: View {
    var body: some View {
        BiometricGatedView(purpose: .walletDetails) {
            WalletContent()
        }
        .navigationTitle(Text("Wallet"))
        .navigationBarTitleDisplayMode(.inline)
        .background(ZunoColor.background)
    }
}

private struct WalletContent: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = WalletModel()
    @State private var showTopUp = false
    @State private var selected: WalletTransaction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch model.summary {
                case .idle, .loading:
                    ShimmerPlaceholder().frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                case .failed(let error):
                    ErrorStateView(error: error) { Task { await model.load(environment: environment) } }.frame(minHeight: 320)
                case .loaded(let summary):
                    balanceCard(summary)
                    allowanceCard(summary)
                    history
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.vertical, 12)
            .readableWidth()
        }
        .background(ZunoColor.background)
        .refreshable { await model.load(environment: environment) }
        .task { await model.load(environment: environment) }
        .sheet(isPresented: $showTopUp, onDismiss: { Task { await model.load(environment: environment) } }) {
            WalletTopUpSheet()
        }
        .sheet(item: $selected) { transaction in
            TransactionDetailSheet(transaction: transaction)
        }
        .zunoContainer("wallet.view")
    }

    private func balanceCard(_ summary: WalletSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Wallet balance", systemImage: "wallet.bifold")
                .font(.subheadline)
                .foregroundStyle(.zunoSecondary)
            Text(ZunoFormat.currency(summary.balance))
                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                .foregroundStyle(.zunoPrimary)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityIdentifier("wallet.balance")
            if summary.pendingTopUps.minorUnits > 0 {
                Text("\(ZunoFormat.currency(summary.pendingTopUps)) pending confirmation")
                    .font(.footnote).foregroundStyle(.zunoAmber)
            }
            if summary.isLowBalance {
                Label("Low balance — top up to keep registering once your free allowance is used.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.zunoAmber)
                    .sensoryFeedback(.warning, trigger: summary.isLowBalance)
            }
            Button {
                showTopUp = true
            } label: {
                Label("Top up", systemImage: "plus")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
            .accessibilityIdentifier("wallet.topUp")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(ZunoColor.surface))
    }

    private func allowanceCard(_ summary: WalletSummary) -> some View {
        SurfaceCard {
            HStack {
                Text("Free registrations").font(.subheadline.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Spacer()
                Text("\(summary.allowanceRemaining) of \(summary.allowanceLimit) left")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(summary.allowanceRemaining == 0 ? ZunoColor.amber : ZunoColor.textSecondary)
            }
            AllowanceMeter(used: summary.allowanceUsed, limit: summary.allowanceLimit)
            Text("Your allowance resets on the 1st of each month. After it's used, each free registration costs \(ZunoFormat.currency(summary.extraFee)) from your wallet — you'll always see the amount before confirming.")
                .font(.footnote)
                .foregroundStyle(.zunoSecondary)
        }
    }

    @ViewBuilder
    private var history: some View {
        SectionHeader(title: Text("Transactions"))
        if model.transactions.isEmpty {
            EmptyStateView(symbol: "tray", title: Text("No transactions yet"),
                           message: Text("Top-ups, registration fees and refunds will appear here."))
                .frame(minHeight: 220)
        } else {
            ForEach(model.groupedTransactions, id: \.month) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.month).font(.footnote.weight(.semibold)).foregroundStyle(.zunoSecondary)
                    ForEach(group.items) { transaction in
                        Button { selected = transaction } label: { WalletRow(transaction: transaction) }
                            .buttonStyle(.plain)
                        if transaction.id != group.items.last?.id {
                            Divider().overlay(ZunoColor.divider)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
            }
        }
    }
}

struct TransactionDetailSheet: View {
    let transaction: WalletTransaction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(ZunoFormat.currency(transaction.amount, showSign: true))
                    .font(.system(size: 36, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.zunoPrimary)
                Text(transaction.description).font(.callout).foregroundStyle(.zunoSecondary)
                SurfaceCard {
                    DetailLine(title: Text("Type"), value: transaction.type.title)
                    DetailLine(title: Text("Status"), value: transaction.status.label)
                    DetailLine(title: Text("Date"), value: ZunoFormat.compactTimestamp(transaction.createdAt))
                    if let after = transaction.balanceAfter {
                        DetailLine(title: Text("Balance after"), value: ZunoFormat.currency(after))
                    }
                    DetailLine(title: Text("Reference"), value: String(transaction.id.uuidString.prefix(8)).uppercased())
                }
                .font(ZunoFont.mono(.footnote))
                if transaction.status == .failed {
                    Text("This top-up didn't complete, so your balance wasn't changed.").font(.footnote).foregroundStyle(.zunoSecondary)
                } else if transaction.status == .pending {
                    Text("Waiting for PayHere to confirm. Your balance updates automatically.").font(.footnote).foregroundStyle(.zunoSecondary)
                }
                Spacer()
            }
            .padding(20)
            .background(ZunoColor.background)
            .navigationTitle(Text(transaction.type.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Wallet top-up through PayHere; the balance changes only after server verification.
struct WalletTopUpSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Money = WalletTopUpPolicy.presets[1]
    @State private var customRupees = ""
    @State private var phone = ""
    @State private var payment = PaymentFlowModel()
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch payment.phase {
                    case .idle, .creating, .awaitingPayment:
                        form
                    default:
                        PaymentStatusView(model: payment, successTitle: Text("Top-up complete"),
                                          successMessage: Text("Your new balance is ready to use.")) { payment.reset() }
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    if payment.isSucceeded {
                        Button("Done") { dismiss() }.buttonStyle(PrimaryCapsuleButtonStyle())
                    } else if case .idle = payment.phase {
                        payButton
                    } else if payment.phase == .creating {
                        payButton
                    }
                }
            }
            .background(ZunoColor.background)
            .navigationTitle(Text("Top up wallet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
                }
            }
        }
        .paymentFlow(payment)
        .presentationDetents([.large])
        .onAppear { phone = session.profile?.phone ?? "" }
        .zunoContainer("wallet.topUpSheet")
    }

    private var payButton: some View {
        Button {
            Task { await pay() }
        } label: {
            Text("Top up \(ZunoFormat.currency(effectiveAmount ?? amount, compact: true))")
        }
        .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: payment.phase == .creating))
        .disabled(effectiveAmount == nil || payment.isBusy)
        .accessibilityIdentifier("wallet.pay")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: Text("Amount"))
            FlowLayout(spacing: 8) {
                ForEach(WalletTopUpPolicy.presets, id: \.self) { preset in
                    SelectableChip(title: Text(ZunoFormat.currency(preset, compact: true)), isSelected: customRupees.isEmpty && amount == preset) {
                        customRupees = ""
                        amount = preset
                    }
                }
            }
            TextField(text: $customRupees, prompt: Text("Other amount (LKR)")) { Text("Other amount") }
                .keyboardType(.numberPad)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
            Text("Between \(ZunoFormat.currency(WalletTopUpPolicy.minimum, compact: true)) and \(ZunoFormat.currency(WalletTopUpPolicy.maximum, compact: true)).")
                .font(.footnote).foregroundStyle(.zunoSecondary)
            SectionHeader(title: Text("Mobile number"))
            TextField(text: $phone, prompt: Text("077 123 4567")) { Text("Mobile number") }
                .keyboardType(.phonePad)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
            if let message = message ?? payment.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Color(uiColor: .systemRed))
            }
        }
    }

    private var effectiveAmount: Money? {
        if customRupees.isEmpty { return amount }
        guard let rupees = Int64(customRupees.filter(\.isNumber)) else { return nil }
        let value = Money.rupees(rupees)
        return WalletTopUpPolicy.validate(value) ? value : nil
    }

    private func pay() async {
        message = nil
        guard let value = effectiveAmount else { message = String(localized: "Choose an amount within the limits."); return }
        guard let normalized = SriLankaLocations.normalizedMobile(phone) else {
            message = String(localized: "Enter a Sri Lankan mobile number, e.g. 077 123 4567.")
            return
        }
        await payment.start(purpose: .walletTopUp(amount: value), phone: normalized, environment: environment)
    }
}
