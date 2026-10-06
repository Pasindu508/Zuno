import Foundation
import Supabase

/// Builds the single shared Supabase client. Sessions are persisted by the SDK in the
/// Keychain (`KeychainLocalStorage`), refreshed automatically, and use PKCE for OAuth.
enum SupabaseClientProvider {
    static func make(configuration: AppConfiguration) -> SupabaseClient? {
        guard let url = configuration.supabaseURL, let key = configuration.supabasePublishableKey else { return nil }
        let options = SupabaseClientOptions(
            db: .init(schema: "public"),
            auth: .init(
                redirectToURL: configuration.oauthRedirectURL,
                flowType: .pkce,
                autoRefreshToken: true,
                emitLocalSessionAsInitialSession: true
            ),
            global: .init(headers: ["X-Client-Info": "zuno-ios/\(Bundle.main.shortVersion)"])
        )
        return SupabaseClient(supabaseURL: url, supabaseKey: key, options: options)
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
}

/// Maps SDK / transport errors to user-facing `ZunoError`s using the contract's codes.
enum SupabaseErrorMapper {
    static func map(_ error: Error) -> Error {
        if error is ZunoError || error is AuthFlowError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                return ZunoError.offline
            case .cancelled:
                return CancellationError()
            default:
                return ZunoError.unknown(urlError.localizedDescription)
            }
        }
        if let postgrest = error as? PostgrestError {
            // RPCs raise `P0001` with the machine code as the message.
            if postgrest.code == "P0001" {
                return ZunoError.fromServerCode(postgrest.message.trimmingCharacters(in: .whitespaces), message: postgrest.details)
            }
            if postgrest.code == "PGRST301" || postgrest.code == "42501" { return ZunoError.notAuthenticated }
            return ZunoError.server(code: postgrest.code ?? "postgrest", message: nil)
        }
        if let functions = error as? FunctionsError {
            if case .httpError(let code, let data) = functions {
                if let body = try? JSONDecoder().decode(FunctionErrorBody.self, from: data) {
                    return ZunoError.fromServerCode(body.error, message: body.message)
                }
                if code == 401 { return ZunoError.notAuthenticated }
                if code == 429 { return ZunoError.rateLimited }
            }
            return ZunoError.server(code: "function", message: nil)
        }
        if let auth = error as? AuthError, auth.errorCode == .sessionNotFound || auth.errorCode == .sessionExpired {
            return ZunoError.notAuthenticated
        }
        return error
    }

    struct FunctionErrorBody: Decodable {
        let error: String
        let message: String?
    }
}
