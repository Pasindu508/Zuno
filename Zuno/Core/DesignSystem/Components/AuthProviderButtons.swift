import AuthenticationServices
import SwiftUI

/// Apple's official `ASAuthorizationAppleIDButton`, unmodified apart from its documented
/// corner radius. No glass or overlays are placed on it.
struct AppleSignInButton: UIViewRepresentable {
    var type: ASAuthorizationAppleIDButton.ButtonType = .continue
    var style: ASAuthorizationAppleIDButton.Style = .white
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: type, authorizationButtonStyle: style)
        button.cornerRadius = 27
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.accessibilityIdentifier = "auth.apple"
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// Google sign-in button following Google's branding guidance: the full-colour "G" mark on
/// a white ("light") button with #1F1F1F text and a neutral outline.
struct GoogleSignInButton: View {
    var title: LocalizedStringKey = "Continue with Google"
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 54

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("GoogleG")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: min(height, 66))
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255).opacity(0.5), lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("auth.google")
    }
}
