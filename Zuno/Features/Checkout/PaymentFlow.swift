import Observation
import SwiftUI
import WebKit

/// Drives one payment: create the server order → launch PayHere → wait for the
/// server-verified status. The browser return URL is never treated as proof of payment.
@MainActor
@Observable
final class PaymentFlowModel {
    enum Phase: Equatable {
        case idle
        case creating
        case awaitingPayment(CheckoutSession)
        case verifying(orderID: UUID)
        case succeeded(OrderSnapshot)
        case failed(String)
        case cancelled
        case expired
        case pendingTimeout(orderID: UUID)
    }

    var phase: Phase = .idle
    var errorMessage: String?
    var resultTrigger = 0
    /// Reused for retries of the same intent so the server never creates two orders.
    private(set) var idempotencyKey = IdempotencyKey.make(prefix: "pay")
    private var pollTask: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .creating, .verifying: true
        default: false
        }
    }

    func start(purpose: CheckoutPurpose, phone: String, environment: AppEnvironment) async {
        errorMessage = nil
        phase = .creating
        do {
            let session = try await environment.checkout.createCheckout(
                CheckoutRequest(purpose: purpose, phone: phone, idempotencyKey: idempotencyKey)
            )
            phase = .awaitingPayment(session)
        } catch {
            phase = .idle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            resultTrigger += 1
        }
    }

    /// Called when the PayHere sheet closes (return, cancel or swipe-down).
    func paymentUIFinished(orderID: UUID, userCancelled: Bool, environment: AppEnvironment) {
        phase = .verifying(orderID: orderID)
        pollTask?.cancel()
        pollTask = Task { await poll(orderID: orderID, userCancelled: userCancelled, environment: environment) }
    }

    private func poll(orderID: UUID, userCancelled: Bool, environment: AppEnvironment) async {
        // A user cancel with no server notification shortly after is reported as cancelled;
        // otherwise poll for up to ~90 s for PayHere's server-to-server notification.
        let deadline = Date.now.addingTimeInterval(userCancelled ? 8 : 90)
        while !Task.isCancelled && Date.now < deadline {
            if let order = try? await environment.checkout.order(id: orderID), order.status.isTerminal {
                finish(with: order)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        phase = userCancelled ? .cancelled : .pendingTimeout(orderID: orderID)
        resultTrigger += 1
    }

    private func finish(with order: OrderSnapshot) {
        switch order.status {
        case .paid: phase = .succeeded(order)
        case .cancelled: phase = .cancelled
        case .expired: phase = .expired
        case .failed, .refunded: phase = .failed(String(localized: "The payment didn't go through. You haven't been charged."))
        case .pending: return
        }
        resultTrigger += 1
    }

    func checkAgain(environment: AppEnvironment) {
        guard case .pendingTimeout(let orderID) = phase else { return }
        paymentUIFinished(orderID: orderID, userCancelled: false, environment: environment)
    }

    /// A new attempt after failure/cancel/expiry is a new intent → new key.
    func reset() {
        pollTask?.cancel()
        idempotencyKey = IdempotencyKey.make(prefix: "pay")
        phase = .idle
    }

    var isSucceeded: Bool { if case .succeeded = phase { return true }; return false }
    var isFailure: Bool {
        switch phase {
        case .failed, .expired: true
        default: false
        }
    }
}

/// Presents the payment surface for the current session and the result states.
struct PaymentPresenter: ViewModifier {
    @Bindable var model: PaymentFlowModel
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content
            .sheet(item: sessionBinding) { session in
                paymentSurface(session)
                    .interactiveDismissDisabled(false)
            }
            .sensoryFeedback(trigger: model.resultTrigger) { _, _ in
                if model.isSucceeded { return .success }
                if model.isFailure || model.errorMessage != nil { return .error }
                return nil
            }
    }

    private var sessionBinding: Binding<CheckoutSession?> {
        Binding {
            if case .awaitingPayment(let session) = model.phase { return session }
            return nil
        } set: { newValue in
            if newValue == nil, case .awaitingPayment(let session) = model.phase {
                model.paymentUIFinished(orderID: session.orderID, userCancelled: true, environment: environment)
            }
        }
    }

    @ViewBuilder
    private func paymentSurface(_ session: CheckoutSession) -> some View {
        switch session.payment {
        case .payHere(let actionURL, let fields, let returnURL, let cancelURL):
            NavigationStack {
                PayHereCheckoutView(actionURL: actionURL, fields: fields, returnURL: returnURL, cancelURL: cancelURL) { cancelled in
                    model.paymentUIFinished(orderID: session.orderID, userCancelled: cancelled, environment: environment)
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("PayHere"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            model.paymentUIFinished(orderID: session.orderID, userCancelled: true, environment: environment)
                        }
                    }
                }
            }
        #if DEBUG
        case .developmentSimulator:
            DevelopmentPaymentSimulator(session: session) { statusCode in
                Task {
                    try? await environment.checkout.simulateGatewayNotification(orderID: session.orderID, statusCode: statusCode)
                }
                model.paymentUIFinished(orderID: session.orderID, userCancelled: statusCode == -1, environment: environment)
            }
        #endif
        }
    }
}

extension View {
    func paymentFlow(_ model: PaymentFlowModel) -> some View {
        modifier(PaymentPresenter(model: model))
    }
}

/// Status view shared by ticket checkout, wallet top-up and event fee payment.
struct PaymentStatusView: View {
    let model: PaymentFlowModel
    let successTitle: Text
    let successMessage: Text
    let onRetry: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .verifying:
                ProgressView().controlSize(.large).tint(ZunoColor.textPrimary)
                Text("Confirming payment…").font(.title3.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text("We're waiting for PayHere to confirm with our server. This usually takes a few seconds.")
                    .font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
            case .succeeded(let order):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52)).foregroundStyle(.zunoAmber)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.7)
                successTitle.zunoDisplay(.section).foregroundStyle(.zunoPrimary)
                successMessage.font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                ReceiptCard(order: order)
            case .failed(let message):
                resultIcon("xmark.circle.fill")
                Text("Payment failed").font(.title3.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text(message).font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                Button("Try again", action: onRetry).buttonStyle(PrimaryCapsuleButtonStyle(compact: true)).frame(maxWidth: 240)
            case .cancelled:
                resultIcon("arrow.uturn.backward.circle.fill")
                Text("Payment cancelled").font(.title3.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text("Nothing was charged. Any tickets held for you have been released.")
                    .font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                Button("Try again", action: onRetry).buttonStyle(PrimaryCapsuleButtonStyle(compact: true)).frame(maxWidth: 240)
            case .expired:
                resultIcon("hourglass")
                Text("Payment window expired").font(.title3.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text("Held tickets are released after 15 minutes. Start again to choose tickets.")
                    .font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                Button("Start again", action: onRetry).buttonStyle(PrimaryCapsuleButtonStyle(compact: true)).frame(maxWidth: 240)
            case .pendingTimeout:
                resultIcon("clock")
                Text("Still waiting for confirmation").font(.title3.weight(.semibold)).foregroundStyle(.zunoPrimary)
                Text(ZunoError.paymentVerificationTimedOut.errorDescription ?? "")
                    .font(.callout).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                Button("Check again") { model.checkAgain(environment: environment) }
                    .buttonStyle(PrimaryCapsuleButtonStyle(compact: true)).frame(maxWidth: 240)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear { withAnimation(ZunoMotion.adaptive(ZunoMotion.reveal, reduceMotion: reduceMotion)) { appeared = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("payment.status")
    }

    private func resultIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 48, weight: .light)).foregroundStyle(.zunoSecondary)
    }
}

/// Digital receipt for a verified order.
struct ReceiptCard: View {
    let order: OrderSnapshot

    var body: some View {
        SurfaceCard {
            DetailLine(title: Text("Order"), value: String(order.id.uuidString.prefix(8)).uppercased())
            DetailLine(title: Text("Paid"), value: order.paidAt.map(ZunoFormat.compactTimestamp) ?? "—")
            DetailLine(title: Text("Total"), value: ZunoFormat.currency(order.total), emphasized: true)
            Text("A receipt is also available in your registration history.")
                .font(.caption).foregroundStyle(.zunoTertiary)
        }
        .font(ZunoFont.mono(.footnote))
        .accessibilityIdentifier("payment.receipt")
    }
}

/// Hosts PayHere's checkout by POSTing the server-signed form in a web view, and
/// watches for the return / cancel URLs to close. Merchant secrets never reach the app.
struct PayHereCheckoutView: UIViewRepresentable {
    let actionURL: URL
    let fields: [String: String]
    let returnURL: String
    let cancelURL: String
    let onFinish: (_ cancelled: Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.loadHTMLString(Self.formHTML(actionURL: actionURL, fields: fields), baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(returnURL: returnURL, cancelURL: cancelURL, onFinish: onFinish) }

    static func formHTML(actionURL: URL, fields: [String: String]) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let inputs = fields.sorted { $0.key < $1.key }
            .map { "<input type=\"hidden\" name=\"\(escape($0.key))\" value=\"\(escape($0.value))\">" }
            .joined()
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="background:#111110;color:#fff;font-family:-apple-system;display:flex;align-items:center;justify-content:center;height:100vh">
        <p>Opening PayHere…</p>
        <form id="f" method="post" action="\(escape(actionURL.absoluteString))">\(inputs)</form>
        <script>document.getElementById('f').submit();</script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let returnURL: String
        let cancelURL: String
        let onFinish: (Bool) -> Void
        private var finished = false

        init(returnURL: String, cancelURL: String, onFinish: @escaping (Bool) -> Void) {
            self.returnURL = returnURL
            self.cancelURL = cancelURL
            self.onFinish = onFinish
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url?.absoluteString else { return .allow }
            if !cancelURL.isEmpty && url.hasPrefix(cancelURL) { finish(cancelled: true); return .cancel }
            if !returnURL.isEmpty && url.hasPrefix(returnURL) { finish(cancelled: false); return .cancel }
            if url.hasPrefix("zuno://") { finish(cancelled: false); return .cancel }
            return .allow
        }

        @MainActor private func finish(cancelled: Bool) {
            guard !finished else { return }
            finished = true
            onFinish(cancelled)
        }
    }
}

#if DEBUG
/// Development backend only. Clearly labelled; drives the same verification path a real
/// signed PayHere notification takes, so every result state can be reviewed.
struct DevelopmentPaymentSimulator: View {
    let session: CheckoutSession
    let onResult: (Int) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Development payment simulator", systemImage: "hammer")
                    .font(.headline)
                    .foregroundStyle(.zunoAmber)
                Text("PayHere isn't configured in this development build. Choose the gateway result to simulate. The app still waits for the server-side order status before issuing anything.")
                    .font(.callout)
                    .foregroundStyle(.zunoSecondary)
                DetailLine(title: Text("Amount"), value: ZunoFormat.currency(session.summary.total), emphasized: true)
                Spacer()
                Button("Approve payment") { onResult(2) }
                    .buttonStyle(PrimaryCapsuleButtonStyle())
                    .accessibilityIdentifier("simulator.approve")
                HStack(spacing: 10) {
                    Button("Decline") { onResult(-2) }.buttonStyle(SecondaryCapsuleButtonStyle())
                        .accessibilityIdentifier("simulator.decline")
                    Button("Cancel") { onResult(-1) }.buttonStyle(SecondaryCapsuleButtonStyle())
                        .accessibilityIdentifier("simulator.cancel")
                    Button("Expire") { onResult(0) }.buttonStyle(SecondaryCapsuleButtonStyle())
                        .accessibilityIdentifier("simulator.expire")
                }
            }
            .padding(24)
            .background(ZunoColor.background)
            .navigationTitle(Text("Payment"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
#endif
