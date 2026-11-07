#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

final class GoogleOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    let clientID: String
    private var session: ASWebAuthenticationSession?
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private let service = "org.rephial.angband.google-drive"

    init(clientID: String) { self.clientID = clientID }

    var isSignedIn: Bool { refreshToken != nil }

    private var callbackScheme: String {
        "com.googleusercontent.apps." + clientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private var refreshToken: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: clientID,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveRefreshToken(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: clientID]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OAuthError.keychain }
    }

    func signOut() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: clientID]
        SecItemDelete(query as CFDictionary)
        accessToken = nil
    }

    func signIn() async throws {
        let verifier = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = UUID().uuidString
        let redirect = "\(callbackScheme):/oauth2redirect"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")]
        let callback = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url.url!,
                callbackURLScheme: callbackScheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? OAuthError.invalidCallback) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: OAuthError.invalidCallback) }
        }
        session = nil
        let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { parts.first { $0.name == name }?.value }
        guard value("state") == state, let code = value("code") else {
            throw OAuthError.authorization(value("error") ?? "Invalid callback")
        }
        let token = try await exchange(["client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect,
            "grant_type": "authorization_code"])
        guard let refresh = token.refreshToken else { throw OAuthError.missingRefreshToken }
        try saveRefreshToken(refresh)
        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))
    }

    func authorizedToken() async throws -> String {
        if let accessToken, Date() < expiresAt { return accessToken }
        guard let refreshToken else { throw OAuthError.notSignedIn }
        let token = try await exchange(["client_id": clientID,
            "refresh_token": refreshToken, "grant_type": "refresh_token"])
        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn - 60))
        return token.accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }

    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OAuthError.authorization(String(data: data, encoding: .utf8) ?? "Token request failed")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    enum OAuthError: LocalizedError {
        case invalidCallback, missingRefreshToken, notSignedIn, keychain, authorization(String)
        var errorDescription: String? {
            switch self {
            case .invalidCallback: "Invalid OAuth redirect"
            case .missingRefreshToken: "Google did not return a refresh token"
            case .notSignedIn: "Sign in to Google Drive first"
            case .keychain: "Could not save Google sign-in in Keychain"
            case .authorization(let detail): "Google sign-in failed: \(detail)"
            }
        }
    }
}
#endif
