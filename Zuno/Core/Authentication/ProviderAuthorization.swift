import AuthenticationServices
import Foundation
import UIKit

// MARK: - Sign in with Apple

/// Seam over `ASAuthorizationController` so UI tests can supply a deterministic credential.
protocol AppleAuthorizing: Sendable {
    @MainActor func authorize(requestNameAndEmail: Bool) async throws -> AppleCredential
    func credentialState(forUserID userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState
}

@MainActor
final class SystemAppleAuthorizer: NSObject, AppleAuthorizing, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var currentNonce: String?

    func authorize(requestNameAndEmail: Bool) async throws -> AppleCredential {
        let nonce = try AppleNonce.generate()
        currentNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // Name and email are only requested when creating an account; Apple returns them
        // on the first authorization only, so linking and re-authentication ask for nothing.
        request.requestedScopes = requestNameAndEmail ? [.fullName, .email] : []
        request.nonce = AppleNonce.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    nonisolated func credentialState(forUserID userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce
            else {
                finish(.failure(AuthFlowError.missingIdentityToken))
                return
            }
            finish(.success(AppleCredential(
                identityToken: token,
                rawNonce: nonce,
                userIdentifier: credential.user,
                fullName: credential.fullName,
                email: credential.email
            )))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let mapped: AuthFlowError
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled: mapped = .cancelled
            case .unknown:
                // Apple reports a revoked or signed-out Apple ID as an unknown error;
                // the launch-time credential-state check handles revocation explicitly.
                mapped = .provider(String(localized: "Sign in with Apple isn't available right now. Check that you're signed in to your Apple Account and try again."))
            default: mapped = .provider(authError.localizedDescription)
            }
        } else if (error as NSError).domain == NSURLErrorDomain {
            mapped = .network
        } else {
            mapped = .provider(error.localizedDescription)
        }
        MainActor.assumeIsolated { finish(.failure(mapped)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.zunoPresentationAnchor }
    }

    private func finish(_ result: Result<AppleCredential, Error>) {
        currentNonce = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - Web authentication (Google OAuth, identity linking)

/// Seam over `ASWebAuthenticationSession`.
protocol WebAuthenticationRunning: Sendable {
    @MainActor func run(url: URL, callbackScheme: String) async throws -> URL
}

@MainActor
final class SystemWebAuthenticationRunner: NSObject, WebAuthenticationRunning, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callbackURL, error in
                MainActor.assumeIsolated { self?.session = nil }
                if let error {
                    if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin {
                        continuation.resume(throwing: AuthFlowError.cancelled)
                    } else if (error as NSError).domain == NSURLErrorDomain {
                        continuation.resume(throwing: AuthFlowError.network)
                    } else {
                        continuation.resume(throwing: AuthFlowError.provider(error.localizedDescription))
                    }
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthFlowError.missingSession)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthFlowError.provider(String(localized: "Couldn't open the sign-in page.")))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.zunoPresentationAnchor }
    }
}

extension UIApplication {
    /// Key window for presenting system authentication UI.
    var zunoPresentationAnchor: UIWindow {
        if let window = zunoKeyWindow { return window }
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        return UIWindow(windowScene: scene)
    }

    var zunoKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { ($0.activationState == .foregroundActive ? 0 : 1) < ($1.activationState == .foregroundActive ? 0 : 1) }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
    }
}

#if DEBUG
/// Deterministic Apple / Google provider stubs for UI tests (`-zuno-stub-providers`).
struct StubAppleAuthorizer: AppleAuthorizing {
    @MainActor func authorize(requestNameAndEmail: Bool) async throws -> AppleCredential {
        try await Task.sleep(for: .milliseconds(300))
        var name = PersonNameComponents()
        name.givenName = "Nethmi"
        name.familyName = "Perera"
        return AppleCredential(identityToken: "stub.apple.token", rawNonce: try AppleNonce.generate(), userIdentifier: "stub-apple-user",
                               fullName: requestNameAndEmail ? name : nil, email: requestNameAndEmail ? "stub@privaterelay.appleid.com" : nil)
    }
    func credentialState(forUserID userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState { .authorized }
}

struct StubWebAuthenticationRunner: WebAuthenticationRunning {
    @MainActor func run(url: URL, callbackScheme: String) async throws -> URL {
        try await Task.sleep(for: .milliseconds(300))
        return URL(string: "\(callbackScheme)://auth/callback?code=stub-code")!
    }
}
#endif
