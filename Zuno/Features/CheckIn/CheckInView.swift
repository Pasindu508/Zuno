import SwiftUI

struct CheckInView: View {
    let eventID: UUID
    var body: some View {
        BiometricGatedView(purpose: .organizerScanning) {
            CheckInContent(eventID: eventID)
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Check-in"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
    }
}

/// Live scanning with server-side validation, manual fallback and restricted offline
/// behaviour (nobody is admitted without the server's atomic check-in).
private struct CheckInContent: View {
    let eventID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var machine = CheckInStateMachine()
    @State private var manualCode = ""
    @State private var stats: OrganizerEventStats?
    @State private var title = ""
    @State private var pulse = false
    @State private var feedback: SensoryFeedback?
    @State private var feedbackTrigger = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                scannerArea
                resultCard
                manualEntry
            }
            .padding(ZunoMetrics.margin)
            .readableWidth(560)
        }
        .task {
            title = (try? await environment.organizer.eventDraft(id: eventID).title) ?? ""
            await refreshStats()
            machine.handle(.startRequested(permission: environment.scanner.cameraPermission()))
            machine.handle(.connectivityChanged(isOnline: network.isOnline))
        }
        .onChange(of: network.isOnline) { _, online in machine.handle(.connectivityChanged(isOnline: online)) }
        .sensoryFeedback(trigger: feedbackTrigger) { _, _ in feedback }
        .zunoContainer("checkin.view")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).zunoDisplay(.cardTitle).foregroundStyle(.zunoPrimary)
            if let stats {
                HStack {
                    Text("\(stats.checkedIn) of \(stats.registrations) checked in")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.zunoSecondary)
                        .contentTransition(.numericText())
                    Spacer()
                }
                ProgressView(value: stats.checkInProgress).tint(ZunoColor.amber)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("checkin.progress")
    }

    @ViewBuilder
    private var scannerArea: some View {
        ZStack {
            switch machine.phase {
            case .requestingPermission:
                permissionPrompt
            case .permissionDenied:
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder").font(.system(size: 36, weight: .light)).foregroundStyle(.zunoSecondary)
                    Text("Camera access is off").font(.headline).foregroundStyle(.zunoPrimary)
                    Text("Allow camera access in Settings, or enter ticket codes manually below.")
                        .font(.footnote).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .frame(maxWidth: 220)
                }
                .padding(24)
            case .offlineRestricted:
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash").font(.system(size: 36, weight: .light)).foregroundStyle(.zunoAmber)
                    Text("Check-in paused").font(.headline).foregroundStyle(.zunoPrimary)
                    Text("Tickets can only be validated online so nobody gets in twice. Reconnect to continue.")
                        .font(.footnote).foregroundStyle(.zunoSecondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .accessibilityIdentifier("checkin.offline")
            default:
                environment.scanner.makeScannerView(isActive: isScanning) { code in
                    detected(code)
                }
                viewfinder
                if case .validating = machine.phase {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .scaleEffect(pulse ? 1.03 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ticket scanner"))
    }

    private var isScanning: Bool {
        switch machine.phase {
        case .scanning, .networkError: true
        default: false
        }
    }

    private var viewfinder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [44, 120], dashPhase: 22))
            .frame(width: 210, height: 210)
            .accessibilityHidden(true)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 40, weight: .light)).foregroundStyle(.white)
            Text("Scan attendee tickets").font(.headline).foregroundStyle(.white)
            Text("Zuno uses the camera only while this screen is open, to read ticket QR codes. Nothing is recorded.")
                .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            Button("Allow camera") {
                Task {
                    let granted = await environment.scanner.requestCameraAccess()
                    machine.handle(.permissionResolved(granted: granted))
                }
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
            .frame(maxWidth: 220)
            .accessibilityIdentifier("checkin.allowCamera")
        }
        .padding(24)
    }

    @ViewBuilder
    private var resultCard: some View {
        switch machine.phase {
        case .result(_, let outcome):
            VStack(alignment: .leading, spacing: 10) {
                Label(outcome.result.title, systemImage: outcome.result.symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(outcome.result.isSuccess ? ZunoColor.onSelectedFill : ZunoColor.textPrimary)
                if let name = outcome.attendeeName {
                    Text(name).font(.body.weight(.medium))
                        .foregroundStyle(outcome.result.isSuccess ? ZunoColor.onSelectedFill : ZunoColor.textPrimary)
                }
                if let tier = outcome.tierName {
                    Text(tier).font(.footnote)
                        .foregroundStyle(outcome.result.isSuccess ? ZunoColor.onSelectedFill.opacity(0.7) : ZunoColor.textSecondary)
                }
                if outcome.result == .alreadyUsed, let at = outcome.checkedInAt {
                    Text("Checked in at \(ZunoFormat.time(at))").font(.footnote).foregroundStyle(.zunoAmber)
                }
                Button("Scan next") { machine.handle(.dismissResult) }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .accessibilityIdentifier("checkin.next")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(outcome.result.isSuccess ? ZunoColor.selectedFill : ZunoColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(outcome.result.isSuccess ? Color.clear : ZunoColor.amber.opacity(0.7), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("checkin.result.\(outcome.result.rawValue)")
        case .networkError:
            Label("Couldn't reach the server. Nothing was recorded — scan again.", systemImage: "wifi.exclamationmark")
                .font(.subheadline).foregroundStyle(.zunoAmber)
                .accessibilityIdentifier("checkin.networkError")
        default:
            EmptyView()
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter code manually").font(.headline).foregroundStyle(.zunoPrimary)
            HStack(spacing: 10) {
                TextField("ZN-XXXX-XXXX", text: $manualCode)
                    .font(ZunoFont.mono(.body))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                    .accessibilityIdentifier("checkin.manualCode")
                Button("Check in") {
                    detected(manualCode, manual: true)
                    manualCode = ""
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                .frame(width: 130)
                .disabled(manualCode.count < 6)
                .accessibilityIdentifier("checkin.manualSubmit")
            }
        }
    }

    private func detected(_ code: String, manual: Bool = false) {
        if case .result = machine.phase { machine.handle(.dismissResult) }
        guard machine.handle(.codeDetected(code, isOnline: network.isOnline, manual: manual)) else { return }
        Task {
            do {
                let outcome = try await environment.checkIn.checkIn(eventID: eventID, code: code)
                machine.handle(.validationFinished(code: code, outcome: outcome))
                feedback = outcome.result.isSuccess ? .success : .error
                feedbackTrigger += 1
                if outcome.result.isSuccess {
                    if !reduceMotion {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pulse = true }
                        try? await Task.sleep(for: .milliseconds(220))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { pulse = false }
                    }
                    await refreshStats()
                }
            } catch {
                machine.handle(.validationFailed(code: code))
                feedback = .error
                feedbackTrigger += 1
            }
        }
    }

    private func refreshStats() async {
        stats = try? await environment.organizer.stats(eventID: eventID)
    }
}
