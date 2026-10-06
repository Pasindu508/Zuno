import CryptoKit
import Foundation
import Security

/// Sign in with Apple nonce handling: a cryptographically secure random nonce is kept on
/// the device, its SHA-256 goes to Apple in the authorization request, and the original
/// nonce goes to Supabase with the identity token so the server can verify the binding.
enum AppleNonce {
    private static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    enum NonceError: Error { case randomGenerationFailed(OSStatus) }

    static func generate(length: Int = 32) throws -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NonceError.randomGenerationFailed(status) }
        // Modulo bias is negligible for a 64-character alphabet (256 is a multiple of 64).
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
