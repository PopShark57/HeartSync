import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Oura OAuth")
struct OuraOAuthTests {

    @Test("Authorization URL requests the client-only OAuth flow and exact scopes")
    func authorizationURL() throws {
        let url = try OuraOAuthSession.authorizationURL(clientID: "public-client-id", state: "state-123")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(url.scheme == "https")
        #expect(url.host == "cloud.ouraring.com")
        #expect(url.path == "/oauth/authorize")
        #expect(values["response_type"] == "token")
        #expect(values["client_id"] == "public-client-id")
        #expect(values["redirect_uri"] == OuraOAuthSession.callbackURL.absoluteString)
        #expect(values["state"] == "state-123")
        #expect(Set((values["scope"] ?? "").split(separator: " ").map(String.init)) == Set(OuraOAuthSession.requestedScopes))
        #expect(Set(OuraOAuthSession.requestedScopes) == [
            "personal", "daily", "heartrate", "workout", "tag", "session", "spo2",
            "stress", "heart_health", "ring_configuration",
        ])
        #expect(values["client_secret"] == nil)
    }

    @Test("Successful callback parses fragment token, expiry, scopes, and state")
    func successfulCallback() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&token_type=bearer&expires_in=2592000&scope=personal+daily+heartrate+spo2Daily&state=expected"
        ))
        let credential = try OuraOAuthSession.parseCallback(callback, expectedState: "expected", now: now)

        #expect(credential.accessToken == "oauth-token")
        #expect(credential.expiresAt == now.addingTimeInterval(2_592_000))
        #expect(credential.grantedScopes == ["personal", "daily", "heartrate", "spo2Daily"])
        #expect(credential.scopeMetadata == .granted(["personal", "daily", "heartrate", "spo2Daily"]))
        #expect(credential.mayAttemptAccess(requiring: "heartrate"))
    }

    @Test("Missing callback scope metadata remains unknown and permits API verification")
    func missingScopeMetadata() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&token_type=bearer&expires_in=3600&state=expected"
        ))
        let credential = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")

        #expect(credential.grantedScopes.isEmpty)
        #expect(credential.scopeMetadata == .unknown)
        #expect(credential.mayAttemptAccess(requiring: "heartrate"))
        #expect(credential.mayAttemptAccess(requiring: "spo2Daily"))
        #expect(credential.mayAttemptAccess(requiring: "spo2"))
    }

    @Test("Explicitly empty callback scope metadata denies scoped endpoint attempts")
    func explicitlyEmptyScopeMetadata() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&token_type=bearer&expires_in=3600&scope=&state=expected"
        ))
        let credential = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")

        #expect(credential.grantedScopes.isEmpty)
        #expect(credential.scopeMetadata == .granted([]))
        #expect(!credential.mayAttemptAccess(requiring: "heartrate"))
        #expect(!credential.mayAttemptAccess(requiring: "spo2Daily"))
        #expect(!credential.mayAttemptAccess(requiring: "spo2"))
    }

    @Test("Callback subset remains exact and recognizes only the documented SpO2 alias")
    func subsetScopeMetadata() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&token_type=bearer&expires_in=3600&scope=daily+spo2&state=expected"
        ))
        let credential = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")

        #expect(credential.grantedScopes == ["daily", "spo2"])
        #expect(credential.scopeMetadata == .granted(["daily", "spo2"]))
        #expect(credential.mayAttemptAccess(requiring: "daily"))
        #expect(credential.mayAttemptAccess(requiring: "spo2Daily"))
        #expect(credential.mayAttemptAccess(requiring: "spo2"))
        #expect(!credential.mayAttemptAccess(requiring: "heartrate"))
    }

    @Test("Oura's 401 missing-scope response is partial permission, not token expiry")
    func scopeDenialIsNotTokenExpiry() {
        #expect(OuraManager.isScopePermissionFailure(
            OuraClient.Failure.unauthorized("Token is not authorized access heart_health scope.")
        ))
        #expect(!OuraManager.isScopePermissionFailure(
            OuraClient.Failure.unauthorized("Access token expired")
        ))
    }

    @Test("Legacy credentials decode without the new scope metadata field")
    func legacyCredentialCompatibility() throws {
        struct LegacyCredential: Encodable {
            var accessToken: String
            var expiresAt: Date
            var grantedScopes: Set<String>
        }

        let legacyKnownData = try JSONEncoder().encode(LegacyCredential(
            accessToken: "legacy-token",
            expiresAt: .distantFuture,
            grantedScopes: ["heartrate"]
        ))
        let legacyKnown = try JSONDecoder().decode(OuraOAuthCredential.self, from: legacyKnownData)
        #expect(legacyKnown.scopeMetadata == .granted(["heartrate"]))

        let legacyAmbiguousData = try JSONEncoder().encode(LegacyCredential(
            accessToken: "legacy-token",
            expiresAt: .distantFuture,
            grantedScopes: []
        ))
        let legacyAmbiguous = try JSONDecoder().decode(OuraOAuthCredential.self, from: legacyAmbiguousData)
        #expect(legacyAmbiguous.scopeMetadata == .unknown)
        #expect(legacyAmbiguous.mayAttemptAccess(requiring: "heartrate"))
    }

    @Test("Callback rejects a mismatched state")
    func rejectsMismatchedState() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&expires_in=3600&state=attacker"
        ))
        do {
            _ = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")
            Issue.record("Expected a state mismatch")
        } catch let failure as OuraOAuthSession.Failure {
            #expect(failure == .stateMismatch)
        }
    }

    @Test("Callback rejects a different redirect target")
    func rejectsDifferentRedirect() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackScheme)://oauth/not-oura#access_token=oauth-token&expires_in=3600&state=expected"
        ))
        do {
            _ = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")
            Issue.record("Expected an invalid callback")
        } catch let failure as OuraOAuthSession.Failure {
            #expect(failure == .invalidCallback)
        }
    }

    @Test("Oura denial is surfaced without accepting a credential")
    func denial() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)?error=access_denied&error_description=User+declined&state=expected"
        ))
        do {
            _ = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")
            Issue.record("Expected an authorization denial")
        } catch let failure as OuraOAuthSession.Failure {
            #expect(failure == .denied("User declined"))
        }
    }

    @Test("Callback rejects a non-bearer token type")
    func rejectsNonBearerToken() throws {
        let callback = try #require(URL(string:
            "\(OuraOAuthSession.callbackURL.absoluteString)#access_token=oauth-token&token_type=mac&expires_in=3600&state=expected"
        ))
        do {
            _ = try OuraOAuthSession.parseCallback(callback, expectedState: "expected")
            Issue.record("Expected an invalid token type")
        } catch let failure as OuraOAuthSession.Failure {
            #expect(failure == .invalidTokenType)
        }
    }

    @Test("Credential validity includes a safety leeway")
    func credentialValidity() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credential = OuraOAuthCredential(
            accessToken: "oauth-token",
            expiresAt: now.addingTimeInterval(120),
            grantedScopes: ["heartrate"]
        )

        #expect(credential.isValid(at: now, leeway: 60))
        #expect(!credential.isValid(at: now.addingTimeInterval(61), leeway: 60))
    }
}
