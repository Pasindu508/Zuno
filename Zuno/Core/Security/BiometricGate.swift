import Foundation
import LocalAuthentication
import Observation
import SwiftUI

enum BiometricKind: Sendable, Equatable {
    case faceID, touchID, opticID, passcode, none

    var title: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: String(localized: "Device passcode")
        case .none: String(localized: "Not available")
        }
    }

    var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID, .opticID: "lock.shield"
        case .passcode, .none: "lock.shield"
        }
    }
}

enum LocalAuthResult: Sendable, Equatable {
    case success
    case cancelled
    case failed
    case lockout
    case notEnrolled
    case passcodeNotSet
    case unavailable
}

/// Seam over LocalAuthentication so tests and UI tests can drive the gate deterministically.
protocol LocalAuthenticator: Sendable {
    func availableKind() -> BiometricKind
    func authenticate(reason: String) async -> LocalAuthResult
}

/// LAContext with `.deviceOwnerAuthentication`: biometrics with device-passcode fallback.
struct SystemLocalAuthenticator: LocalAuthenticator {
    func availableKind() -> BiometricKind {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: break
            }
        }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? .passcode : .none
    }

    func authenticate(reason: String) async -> LocalAuthResult {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return Self.map(error)
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return Self.map(error as NSError)
        }
    }

    private static func map(_ error: NSError?) -> LocalAuthResult {
        guard let error, error.domain == LAError.errorDomain else { return .unavailable }
        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
        case .authenticationFailed: return .failed
        case .biometryLockout: return .lockout
        case .biometryNotEnrolled: return .notEnrolled
        case .passcodeNotSet: return .passcodeNotSet
        default: return .unavailable
        }
    }
}

/// What a gate protects. Identity linking and account changes always require fresh local
/// authentication; the rest are protected when the user turns on App Lock.
enum SensitivePurpose: Sendable, Hashable {
    case walletDetails, ticketDetails, organizerScanning, organizerFinancials, identityLinking, accountChange

    var alwaysRequired: Bool { self == .identityLinking || self == .accountChange }

    var reason: String {
        switch self {
        case .walletDetails: String(localized: "Unlock to view your wallet.")
        case .ticketDetails: String(localized: "Unlock to view your ticket details.")
        case .organizerScanning: String(localized: "Unlock to start scanning tickets.")
        case .organizerFinancials: String(localized: "Unlock to view sales and settlements.")
        case .identityLinking: String(localized: "Confirm it's you before changing sign-in methods.")
        case .accountChange: String(localized: "Confirm it's you before changing your account.")
        }
    }
}

/// Biometrics supplement the Supabase session; they never replace server authentication.
@MainActor
@Observable
final class BiometricGate {
    private(set) var isAppLockEnabled: Bool
    private(set) var unlockedPurposes: Set<SensitivePurpose> = []
    private(set) var lastMessage: String?
    private let authenticator: LocalAuthenticator
    private let keychain: Keychain
    private var unlockedAt: [SensitivePurpose: Date] = [:]
    private let gracePeriod: TimeInterval = 120

    private static let appLockKey = "app-lock-enabled"

    init(authenticator: LocalAuthenticator, keychain: Keychain = .standard) {
        self.authenticator = authenticator
        self.keychain = keychain
        isAppLockEnabled = keychain.bool(for: Self.appLockKey)
    }

    var availableKind: BiometricKind { authenticator.availableKind() }

    func requiresUnlock(_ purpose: SensitivePurpose, now: Date = .now) -> Bool {
        guard purpose.alwaysRequired || isAppLockEnabled else { return false }
        if purpose.alwaysRequired { return true } // fresh authentication every time
        guard let at = unlockedAt[purpose] else { return true }
        return now.timeIntervalSince(at) > gracePeriod
    }

    /// Returns `true` when the protected action may proceed.
    func authorize(_ purpose: SensitivePurpose) async -> Bool {
        guard requiresUnlock(purpose) else { return true }
        let result = await authenticator.authenticate(reason: purpose.reason)
        switch result {
        case .success:
            unlockedAt[purpose] = .now
            unlockedPurposes.insert(purpose)
            lastMessage = nil
            return true
        case .cancelled:
            lastMessage = nil
        case .failed:
            lastMessage = String(localized: "We couldn't confirm it's you. Try again.")
        case .lockout:
            lastMessage = String(localized: "Biometrics are locked. Use your device passcode in Settings to re-enable them, then try again.")
        case .notEnrolled, .passcodeNotSet, .unavailable:
            // No local authentication exists on this device. Optional App Lock purposes
            // proceed (the server session still protects data); identity changes don't.
            if !purpose.alwaysRequired { return true }
            lastMessage = String(localized: "Set a device passcode to change sign-in methods.")
        }
        return false
    }

    func setAppLock(enabled: Bool) async -> Bool {
        if enabled {
            let result = await authenticator.authenticate(reason: String(localized: "Turn on App Lock for Zuno."))
            guard result == .success else {
                lastMessage = result == .notEnrolled || result == .passcodeNotSet
                    ? String(localized: "Set up Face ID, Touch ID or a passcode in Settings first.") : nil
                return false
            }
        }
        isAppLockEnabled = enabled
        keychain.set(enabled, for: Self.appLockKey)
        return true
    }

    /// Forget unlocks when the app goes to the background or the user signs out.
    func lock() {
        unlockedAt.removeAll()
        unlockedPurposes.removeAll()
    }

    func reset() {
        lock()
        isAppLockEnabled = false
        keychain.remove(Self.appLockKey)
    }
}

#if DEBUG
/// Deterministic authenticator for UI tests (`-zuno-biometric success|failure`).
struct StubLocalAuthenticator: LocalAuthenticator {
    var outcome: LocalAuthResult
    func availableKind() -> BiometricKind { .faceID }
    func authenticate(reason: String) async -> LocalAuthResult {
        try? await Task.sleep(for: .milliseconds(250))
        return outcome
    }
}
#endif

/// Wraps protected content: shows a locked placeholder until the gate authorizes.
struct BiometricGatedView<Content: View>: View {
    let purpose: SensitivePurpose
    @ViewBuilder var content: () -> Content
    @Environment(BiometricGate.self) private var gate
    @State private var unlocked = false
    @State private var attempting = false

    var body: some View {
        Group {
            if unlocked {
                content()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: gate.availableKind.symbolName)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.zunoSecondary)
                        .accessibilityHidden(true)
                    Text("Locked")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.zunoPrimary)
                    Text(purpose.reason)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.zunoSecondary)
                    if let message = gate.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.zunoAmber)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await attempt() }
                    } label: {
                        Text("Unlock with \(gate.availableKind.title)")
                    }
                    .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                    .disabled(attempting)
                    .accessibilityIdentifier("biometric.unlock")
                }
                .padding(32)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZunoColor.background)
                .zunoContainer("biometric.locked")
            }
        }
        .task { await attempt() }
    }

    private func attempt() async {
        guard !unlocked, !attempting else { return }
        attempting = true
        unlocked = await gate.authorize(purpose)
        attempting = false
    }
}
