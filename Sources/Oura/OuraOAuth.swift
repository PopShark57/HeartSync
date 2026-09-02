import AuthenticationServices
import Foundation
import Security
import UIKit

/// The OAuth credential returned by Oura's client-side flow.
///
/// Oura does not issue a refresh token for this flow. The access token currently lasts
/// about 30 days; once it expires, the user authorizes the app again in the secure browser
/// session. Keeping the whole record in one keychain item makes updates atomic.
struct OuraOAuthCredential: Codable, Equatable, Sendable {
    enum ScopeMetadata: Equatable, Sendable {
        /// Oura did not include a `scope` field in the callback. The access token is still
        /// valid, so callers may ask the API and let the server make the authorization
        /// decision rather than treating every permission as denied locally.
        case unknown
        /// Oura explicitly returned this set. An empty set therefore means the user did
        /// not grant any of the requested data permissions.
        case granted(Set<String>)
    }

    var accessToken: String
    var expiresAt: Date
    var grantedScopes: Set<String>
    /// Optional keeps credentials written by the previous release decodable. A legacy
    /// nonempty set is authoritative; a legacy empty set is ambiguous and treated as
    /// unknown so an otherwise valid token can still be checked with Oura.
    var scopeFieldWasReturned: Bool?

    init(
        accessToken: String,
        expiresAt: Date,
        grantedScopes: Set<String>,
        scopeFieldWasReturned: Bool? = nil
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
        self.scopeFieldWasReturned = scopeFieldWasReturned
    }

    var scopeMetadata: ScopeMetadata {
        switch scopeFieldWasReturned {
        case true:
            .granted(grantedScopes)
        case false:
            .unknown
        case nil:
            grantedScopes.isEmpty ? .unknown : .granted(grantedScopes)
        }
    }

    /// Whether it is reasonable to request an endpoint protected by `scope`.
    ///
    /// Unknown callback metadata deliberately permits the attempt; Oura remains the
    /// authority and may answer with a permission error. Oura has returned both `spo2` and
    /// `spo2Daily` for the blood-oxygen permission, so those names are treated as aliases.
    func mayAttemptAccess(requiring scope: String) -> Bool {
        switch scopeMetadata {
        case .unknown:
            return true
        case .granted(let scopes):
            if scope == "spo2" || scope == "spo2Daily" {
                return scopes.contains("spo2Daily") || scopes.contains("spo2")
            }
            return scopes.contains(scope)
        }
    }

    func isValid(at date: Date = .now, leeway: TimeInterval = 60) -> Bool {
        !accessToken.isEmpty && expiresAt.timeIntervalSince(date) > leeway
    }
}

enum OuraOAuthCredentialStore {
    static func load() -> OuraOAuthCredential? {
        guard let encoded = Keychain.get(.ouraOAuthCredentials),
              let data = Data(base64Encoded: encoded)
        else { return nil }
        return try? JSONDecoder().decode(OuraOAuthCredential.self, from: data)
    }

    @discardableResult
    static func save(_ credential: OuraOAuthCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        let saved = Keychain.set(data.base64EncodedString(), for: .ouraOAuthCredentials)
        if saved { Keychain.delete(.ouraPersonalAccessToken) }
        return saved
    }

    @discardableResult
    static func clear() -> Bool {
        let oauthCleared = Keychain.delete(.ouraOAuthCredentials)
        // Remove credentials saved by releases that still used Oura personal access tokens.
        let legacyCleared = Keychain.delete(.ouraPersonalAccessToken)
        return oauthCleared && legacyCleared
    }
}

/// Runs Oura's documented client-side OAuth flow in Apple's protected web-authentication
/// browser. This avoids embedding an Oura client secret in the app binary.
@MainActor
final class OuraOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {

    nonisolated static let applicationPortalURL = URL(string: "https://developer.ouraring.com/applications")!
    nonisolated static let authorizationEndpoint = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    nonisolated static let revocationEndpoint = URL(string: "https://api.ouraring.com/oauth/revoke")!
    nonisolated static let callbackScheme = "com.heartsync.heartsyncchecker"
    nonisolated static let callbackURL = URL(string: "\(callbackScheme)://oauth/oura")!
    nonisolated static let requestedScopes = [
        "personal", "daily", "heartrate", "workout", "tag", "session", "spo2",
        "stress", "heart_health", "ring_configuration",
    ]

    enum Failure: LocalizedError, Equatable {
        case missingClientID
        case couldNotStart
        case cancelled
        case invalidCallback
        case stateMismatch
        case denied(String?)
        case missingAccessToken
        case invalidTokenType
        case invalidExpiration
        case system(String)

        /// User-facing failure text. "Client ID", "redirect URI", and "OAuth" are terms
        /// the user reads verbatim in Oura's own developer console, so a translation
        /// should keep whatever wording that console uses in the same language.
        var errorDescription: String? {
            switch self {
            case .missingClientID:
                String(localized: "ouraOAuth.failure.missingClientID", defaultValue: "Enter the Client ID from your Oura OAuth application.", comment: "Oura sign-in error: no client ID configured")
            case .couldNotStart:
                String(localized: "ouraOAuth.failure.couldNotStart", defaultValue: "Could not open Oura sign-in. Please try again.", comment: "Oura sign-in error: the web authentication session would not start")
            case .cancelled:
                String(localized: "ouraOAuth.failure.cancelled", defaultValue: "Oura sign-in was cancelled.", comment: "Oura sign-in error: the user dismissed the sheet")
            case .invalidCallback:
                String(localized: "ouraOAuth.failure.invalidCallback", defaultValue: "Oura returned to an unexpected callback address. Check the redirect URI in your Oura application.", comment: "Oura sign-in error: the callback URL did not match the expected scheme, host, or path")
            case .stateMismatch:
                String(localized: "ouraOAuth.failure.stateMismatch", defaultValue: "Oura sign-in could not be verified. Please start it again.", comment: "Oura sign-in error: the OAuth state value did not match the one sent")
            case .denied(let reason):
                reason.map {
                    String(localized: "ouraOAuth.failure.denied.reason", defaultValue: "Oura authorization was denied: \($0)", comment: "Oura sign-in error: denied, with the reason Oura reported")
                } ?? String(localized: "ouraOAuth.failure.denied", defaultValue: "Oura authorization was denied.", comment: "Oura sign-in error: denied with no reason given")
            case .missingAccessToken:
                String(localized: "ouraOAuth.failure.missingAccessToken", defaultValue: "Oura did not return an access token. Please try again.", comment: "Oura sign-in error: the callback carried no access token")
            case .invalidTokenType:
                String(localized: "ouraOAuth.failure.invalidTokenType", defaultValue: "Oura returned an unsupported token type. Please try again.", comment: "Oura sign-in error: the token type was not the expected bearer token")
            case .invalidExpiration:
                String(localized: "ouraOAuth.failure.invalidExpiration", defaultValue: "Oura returned an invalid token expiration. Please try again.", comment: "Oura sign-in error: the expires_in value could not be used")
            case .system(let message):
                String(localized: "ouraOAuth.failure.system", defaultValue: "Could not complete Oura sign-in: \(message)", comment: "Oura sign-in error: an underlying system error. The placeholder is the system message.")
            }
        }
    }

    private var webSession: ASWebAuthenticationSession?
    private var presentationWindow: UIWindow?

    func authorize(clientID: String) async throws -> OuraOAuthCredential {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw Failure.missingClientID }

        let state = Self.randomState()
        let authorizationURL = try Self.authorizationURL(clientID: clientID, state: state)
        guard let activeWindow = Self.activePresentationWindow() else {
            throw Failure.couldNotStart
        }
        presentationWindow = activeWindow

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let callback = ASWebAuthenticationSession.Callback.customScheme(Self.callbackScheme)
                let session = ASWebAuthenticationSession(
                    url: authorizationURL,
                    callback: callback
                ) { [weak self] callbackURL, error in
                    self?.webSession = nil
                    self?.presentationWindow = nil

                    if let authenticationError = error as? ASWebAuthenticationSessionError,
                       authenticationError.code == .canceledLogin {
                        continuation.resume(throwing: Failure.cancelled)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: Failure.system(error.localizedDescription))
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: Failure.invalidCallback)
                        return
                    }

                    do {
                        continuation.resume(returning: try Self.parseCallback(
                            callbackURL,
                            expectedState: state
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                webSession = session

                guard session.start() else {
                    webSession = nil
                    presentationWindow = nil
                    continuation.resume(throwing: Failure.couldNotStart)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        webSession?.cancel()
        webSession = nil
    }

    /// `authorize` captures a real window from a foreground scene before starting the
    /// session, so the common path returns exactly the window the user tapped in and cannot
    /// drift to a different iPad window between the tap and presentation.
    ///
    /// It is not, however, the only path. `ASWebAuthenticationSession` may ask for an anchor
    /// again — after a scene change, or once the completion handler has already cleared the
    /// captured window — and force-unwrapping put a crash in the middle of the OAuth flow
    /// for that. The fallbacks re-find an active window and, failing even that, hand back an
    /// empty window rather than trapping: a sign-in sheet that fails to present is a bad
    /// outcome, and terminating the app over it is a worse one.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let presentationWindow { return presentationWindow }
        if let active = Self.activePresentationWindow() {
            presentationWindow = active
            return active
        }
        return Self.lastResortWindow()
    }

    // MARK: - Pure OAuth helpers (also exercised by unit tests)

    nonisolated static func authorizationURL(clientID: String, state: String) throws -> URL {
        guard !clientID.isEmpty else { throw Failure.missingClientID }
        var components = URLComponents(
            url: authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: requestedScopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw Failure.couldNotStart }
        return url
    }

    nonisolated static func parseCallback(
        _ url: URL,
        expectedState: String,
        now: Date = .now
    ) throws -> OuraOAuthCredential {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host?.lowercased() == callbackURL.host,
              url.path == callbackURL.path
        else { throw Failure.invalidCallback }

        // Oura documents the fragment as application/x-www-form-urlencoded. Unlike
        // URLComponents.queryItems, form decoding must turn `+` into a space.
        let values = Dictionary(
            formPairs(url.query) + formPairs(url.fragment),
            uniquingKeysWith: { _, newest in newest }
        )

        guard values["state"] == expectedState else { throw Failure.stateMismatch }
        if let error = values["error"] {
            throw Failure.denied(values["error_description"] ?? error)
        }
        guard let accessToken = values["access_token"], !accessToken.isEmpty else {
            throw Failure.missingAccessToken
        }
        guard values["token_type"]?.lowercased() == "bearer" else {
            throw Failure.invalidTokenType
        }
        guard let expirationText = values["expires_in"],
              let expiration = TimeInterval(expirationText),
              expiration > 0
        else { throw Failure.invalidExpiration }

        let scopeField = values["scope"]
        let scopes = Set((scopeField ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init))
        return OuraOAuthCredential(
            accessToken: accessToken,
            expiresAt: now.addingTimeInterval(expiration),
            grantedScopes: scopes,
            scopeFieldWasReturned: scopeField != nil
        )
    }

    /// Oura documents access-token revocation as a request with the token in the URL.
    /// This is best-effort because local removal must still work while offline. The URL is
    /// deliberately never logged.
    nonisolated static func revoke(
        accessToken: String,
        session: URLSession = .shared
    ) async {
        guard !accessToken.isEmpty else { return }
        var components = URLComponents(url: revocationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        _ = try? await session.data(for: request)
    }

    nonisolated private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func formPairs(_ encoded: String?) -> [(String, String)] {
        guard let encoded else { return [] }
        return encoded.split(separator: "&", omittingEmptySubsequences: true).compactMap { field in
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first else { return nil }
            let rawValue = pieces.count == 2 ? String(pieces[1]) : ""
            return (formDecode(String(rawName)), formDecode(rawValue))
        }
    }

    nonisolated private static func formDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? value.replacingOccurrences(of: "+", with: " ")
    }

    private static func activePresentationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Only reached when no scene is foreground-active, which is not a state a user-initiated
    /// sign-in can normally be in. Any existing window is preferable to a fresh one; the
    /// empty window is the floor that keeps `presentationAnchor` total.
    private static func lastResortWindow() -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let existing = scenes.flatMap(\.windows).first { return existing }
        if let scene = scenes.first { return UIWindow(windowScene: scene) }
        return UIWindow()
    }
}
