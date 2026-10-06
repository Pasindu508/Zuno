import SwiftUI

/// NIC duplicate-prevention step. The number is sent once over TLS to a protected Edge
/// Function that stores only a keyed HMAC digest; the app never stores, hashes or logs it.
struct IdentitySetupView: View {
    enum Presentation { case onboarding, settings }
    let presentation: Presentation

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var nic = ""
    @State private var reveal = false
    @State private var submitting = false
    @State private var result: IdentityCheckResult?
    @State private var error: String?
    @State private var feedback = 0
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.zunoAmber)
                        .accessibilityHidden(true)
                    Text("One account per person")
                        .zunoDisplay(.detailTitle)
                        .foregroundStyle(.zunoPrimary)
                    Text("Free registrations are limited to 15 a month for each person. To keep that fair, we check that your NIC isn't already linked to another Zuno account.")
                        .font(.body)
                        .foregroundStyle(.zunoSecondary)
                }

                if session.profile?.identityStatus == .verifiedUnique || result == .verifiedUnique {
                    SurfaceCard {
                        Label("Identity setup complete", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.zunoPrimary)
                        Text("Your NIC isn't linked to any other account. You can register for events.")
                            .font(.callout).foregroundStyle(.zunoSecondary)
                    }
                    .zunoContainer("identity.verified")
                } else if result == .duplicate {
                    SurfaceCard {
                        Label("This NIC is already in use", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.zunoAmber)
                        Text("Another Zuno account already registered this number. If that's an old account of yours, sign in to it instead. If you think this is a mistake, contact support@zuno.lk — we can't see your number, only that it matched.")
                            .font(.callout).foregroundStyle(.zunoSecondary)
                    }
                    .zunoContainer("identity.duplicate")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("National Identity Card number").font(.headline).foregroundStyle(.zunoPrimary)
                        HStack {
                            Group {
                                if reveal {
                                    TextField("200012345678 or 851234567V", text: $nic)
                                } else {
                                    SecureField("200012345678 or 851234567V", text: $nic)
                                }
                            }
                            .font(ZunoFont.mono(.body))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.none)
                            .accessibilityIdentifier("identity.nic")
                            Button { reveal.toggle() } label: {
                                Image(systemName: reveal ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.zunoSecondary)
                            .accessibilityLabel(reveal ? Text("Hide number") : Text("Show number"))
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        if !nic.isEmpty && !NICInput.isPlausible(nic) {
                            Text("Enter 12 digits, or 9 digits followed by V or X.").font(.footnote).foregroundStyle(.zunoAmber)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color(uiColor: .systemRed))
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        bullet("We never store your NIC number. Our server turns it into a one-way keyed fingerprint (HMAC) and keeps only that.")
                        bullet("The number is never written to logs, analytics or this device.")
                        bullet("A matching fingerprint only tells us the same number was used before. It doesn't verify that the NIC belongs to you.")
                        bullet("Deleting your account deletes the fingerprint.")
                    }
                    .padding(.top, 8)
                } label: {
                    Text("How we protect your NIC").font(.subheadline.weight(.semibold)).foregroundStyle(.zunoPrimary)
                }
                .tint(ZunoColor.textPrimary)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.vertical, 20)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) { actions }
        .background(ZunoColor.background.ignoresSafeArea())
        .sensoryFeedback(trigger: feedback) { _, _ in
            result == .verifiedUnique ? .success : .error
        }
        .navigationTitle(presentation == .settings ? Text("Identity") : Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .zunoContainer("identity.view")
    }

    @ViewBuilder
    private var actions: some View {
        BottomActionBar {
            if session.profile?.identityStatus == .verifiedUnique || result == .verifiedUnique {
                Button("Continue") { finish() }
                    .buttonStyle(PrimaryCapsuleButtonStyle())
                    .accessibilityIdentifier("identity.continue")
            } else if result != .duplicate {
                Button("Check and continue") { Task { await submit() } }
                    .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: submitting))
                    .disabled(!NICInput.isPlausible(nic) || submitting)
                    .accessibilityIdentifier("identity.submit")
            }
            if presentation == .onboarding && result != .verifiedUnique {
                Button("Not now — browse first") { session.deferIdentitySetup() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.zunoSecondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("identity.later")
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(ZunoColor.amber).frame(width: 5, height: 5).padding(.top, 7)
            Text(text).font(.footnote).foregroundStyle(.zunoSecondary)
        }
    }

    private func submit() async {
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            result = try await environment.profiles.submitNationalIdentifier(nic)
            nic = "" // drop the value from memory as soon as it's sent
            feedback += 1
            // In settings, refresh the profile now; during onboarding the confirmation stays on
            // screen until the user taps Continue (which then refreshes and routes).
            if result == .verifiedUnique, presentation == .settings { await session.identityCompleted() }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedback += 1
        }
    }

    private func finish() {
        switch presentation {
        case .onboarding: Task { await session.identityCompleted() }
        case .settings: dismiss()
        }
    }
}
