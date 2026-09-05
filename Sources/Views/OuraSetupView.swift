import SwiftUI
// UIPasteboard only. SwiftUI has no plain-string clipboard API, and the redirect URI has to
// be transferable in one tap: it is long, monospaced, and Oura rejects the sign-in outright
// if a single character of it differs.
import UIKit

/// How close the stored Oura OAuth credential is to expiring.
///
/// HeartSync's OAuth flow is client-side and issues no refresh token, so the credential does
/// not renew — it simply dies, roughly monthly. Without a warning the first symptom a user
/// sees is a sync that failed, on a screen that cannot explain why. This turns the expiry
/// date into a state both the Devices list and the setup sheet can surface *before* that
/// happens.
///
/// `warningWindow` is deliberately generous: re-authorizing needs a web round trip through
/// Oura's site, which the user may not be able to do the moment they first notice.
enum OuraAuthorizationExpiry: Equatable, Sendable {
    /// No credential is stored, or Oura reported no expiry.
    case none
    /// Stored and not close to expiring.
    case comfortable
    case expiringSoon(Date)
    case expired

    /// How long before expiry the UI starts asking for a re-authorization.
    static let warningWindow: TimeInterval = 7 * 86_400

    init(expiresAt: Date?, now: Date = .now) {
        guard let expiresAt else {
            self = .none
            return
        }
        if expiresAt <= now {
            self = .expired
        } else if expiresAt.timeIntervalSince(now) <= Self.warningWindow {
            self = .expiringSoon(expiresAt)
        } else {
            self = .comfortable
        }
    }

    /// Plain-language prompt, or nil when there is nothing worth interrupting the user for.
    /// Every call site uses this as the visible text, so a nil message is also the signal
    /// that no warning row should be shown at all.
    var message: String? {
        switch self {
        case .none, .comfortable:
            return nil
        case .expiringSoon(let date):
            return "Oura authorization expires \(date.formatted(.relative(presentation: .named)))."
        case .expired:
            return "Oura authorization has expired. Syncing will fail until you authorize again."
        }
    }

    var systemImage: String {
        switch self {
        case .none, .comfortable: "checkmark.circle"
        case .expiringSoon:       "clock.badge.exclamationmark"
        case .expired:            "exclamationmark.triangle.fill"
        }
    }

    /// Colour is a reinforcement here, never the only carrier: `message` states the
    /// situation in words and every call site uses it as the visible text.
    var tint: Color {
        switch self {
        case .none, .comfortable: .secondary
        case .expiringSoon:       .orange
        case .expired:            .red
        }
    }
}

/// Oura connection sheet. Authentication happens in an ASWebAuthenticationSession; the
/// app receives a scoped OAuth access token and stores it in the device-only keychain.
struct OuraSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// An OAuth client ID is public configuration, not a client secret. Keeping it in app
    /// preferences lets personal builds connect without compiling credentials into source.
    ///
    /// There is deliberately no default value: HeartSync has no first-party OAuth
    /// application to ship, and inventing one would be a credential this repository does not
    /// own. The three setup steps below exist because of that, not by preference.
    @AppStorage("oura.oauth.client-id") private var clientID = ""
    @State private var isAuthorizing = false
    @State private var didCopyRedirectURI = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This build treats Oura as an advanced optional integration for personal/developer use. Bluetooth and Apple Health remain fully usable without it. HeartSync does not ship a shared production Oura client identity, so setup requires your own Oura OAuth application.")
                        .font(.subheadline.weight(.medium))
                    Text("You sign in on Oura's site and choose which read-only data to share; HeartSync never sees your password.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                expirySection
                missingScopesSection
                setupSection
                clientIDSection
                errorSection
                connectSection
                permissionsSection
            }
            .navigationTitle("Connect Oura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.oura.cancelAuthorization()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    /// Warns before the credential dies rather than after a sync has already failed.
    @ViewBuilder
    private var expirySection: some View {
        let expiry = OuraAuthorizationExpiry(expiresAt: model.oura.authorizationExpiresAt)
        if let message = expiry.message {
            Section {
                Label(message, systemImage: expiry.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(expiry.tint)
                    .accessibilityLabel(message)
            } header: {
                Text("Re-authorization needed")
            } footer: {
                Text("Oura's client-side sign-in issues no refresh token, so HeartSync cannot renew this quietly in the background. Continue below to authorize again \u{2014} your Client ID, your settings, and every reading already stored are kept.")
            }
        }
    }

    @ViewBuilder
    private var missingScopesSection: some View {
        if !model.oura.missingRequestedScopes.isEmpty {
            let message = "Your current authorization is missing \(model.oura.missingRequestedScopes.map(scopeTitle).joined(separator: ", ")). Continue below and enable those permissions on Oura's consent screen."
            Section {
                Label(message, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(message)
            } header: {
                Text("Update permissions")
            }
        }
    }

    private var setupSection: some View {
        Section {
            step(
                1,
                "Create an Oura OAuth application",
                "HeartSync has no server and no shared credential to hand you, so the application has to be your own. It is free and takes about a minute."
            )
            Button {
                openURL(OuraOAuthSession.applicationPortalURL)
            } label: {
                Label("Open Oura API Applications", systemImage: "safari")
            }
            .accessibilityHint("Opens developer.ouraring.com in your browser")

            step(
                2,
                "Add this redirect URI to it",
                "Paste it into the application's Redirect URIs field exactly as shown. Oura refuses the sign-in if a single character differs."
            )
            redirectURIRow

            step(
                3,
                "Copy the application's Client ID",
                "It is on the same page, next to the Client Secret. Paste only the Client ID below \u{2014} the secret is never used and must not be entered."
            )
        } header: {
            Text("One-time setup")
        } footer: {
            Text("You only do this once per device. After that, connecting is a single sign-in.")
        }
    }

    private var redirectURIRow: some View {
        Button {
            copyRedirectURI()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(OuraOAuthSession.callbackURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(
                    didCopyRedirectURI ? "Copied" : "Copy",
                    systemImage: didCopyRedirectURI ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(didCopyRedirectURI ? Color.green : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Copy redirect URI")
        .accessibilityValue(OuraOAuthSession.callbackURL.absoluteString)
        .accessibilityHint("Copies the redirect URI so you can paste it into your Oura application")
    }

    private var clientIDSection: some View {
        Section {
            TextField("Oura Client ID", text: $clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Oura Client ID")
                .accessibilityHint(clientIDIssue?.message ?? "Paste the Client ID from your Oura application")

            if let issue = clientIDIssue {
                Label(issue.message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Client ID problem. \(issue.message)")
            }
        } header: {
            Text("OAuth Client ID")
        } footer: {
            Text("The Client ID identifies your OAuth application and is not secret. Do not enter or embed the Client Secret; HeartSync's client-side OAuth flow does not use it.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if case .error(let message) = model.oura.status {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .accessibilityLabel("Oura error. \(message)")
            }
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                connect()
            } label: {
                HStack {
                    if isAuthorizing { ProgressView().controlSize(.small) }
                    Text(connectTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canConnect)
            .accessibilityLabel(connectTitle)
            .accessibilityHint("Opens Oura's sign-in page, where you choose which read-only data to share")
        }
    }

    private var permissionsSection: some View {
        Section {
            permission("Daily health", "Sleep, activity, readiness, and daily recovery summaries")
            permission("Heart rate", "Five-minute heart-rate samples after the ring syncs")
            permission("Blood oxygen", "Nightly SpO\u{2082} and breathing-disturbance summaries")
            permission("Stress & resilience", "Daily stress, recovery, and resilience signals")
            permission("Heart health", "Cardiovascular age and VO\u{2082} max")
            permission("Personal and ring", "Profile, ring configuration, and battery")
            permission("Workouts, sessions, and tags", "Your activity timeline and Oura-processed motion counts")
        } header: {
            Text("Requested read-only access")
        } footer: {
            Text("You can decline individual permissions. HeartSync will keep the account connected and mark only that data unavailable. The OAuth token stays in this device's Keychain; the client-side flow requires authorization again after it expires, and HeartSync warns you before that happens.")
        }
    }

    // MARK: - Client ID validation

    /// A locally decidable problem with the pasted Client ID.
    ///
    /// Shape only, and deliberately so. HeartSync cannot tell a well-formed but wrong Client
    /// ID from the right one without a round trip to Oura, so this catches just the mistakes
    /// that *are* decidable on device — a pasted URL, clipboard whitespace, a truncated copy
    /// — and stays silent otherwise rather than rejecting a format Oura may legitimately
    /// change. Nothing here blocks a value that only *looks* unusual: the length bounds are
    /// wide, and the reference to 32 characters is stated as Oura's current shape, not as a
    /// rule this app enforces.
    private enum ClientIDIssue: Equatable {
        case containsWhitespace
        case looksLikeURL
        case invalidCharacters(String)
        case tooShort(Int)
        case tooLong(Int)

        var message: String {
            switch self {
            case .containsWhitespace:
                "A Client ID is one unbroken word, and this one has a space in it. You may have copied some surrounding text as well."
            case .looksLikeURL:
                "That looks like a web address. Paste the Client ID from your Oura application, not the redirect URI."
            case .invalidCharacters(let characters):
                "A Client ID is letters and digits only. Remove \(characters)."
            case .tooShort(let count):
                "That is only \(count) character\(count == 1 ? "" : "s"). Oura Client IDs are 32 \u{2014} check that the whole value was copied."
            case .tooLong(let count):
                "That is \(count) characters. Oura Client IDs are 32 \u{2014} make sure this is not the Client Secret or an access token."
            }
        }
    }

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the field is empty — there is nothing to complain about before the user has
    /// typed — or when the value looks usable.
    private var clientIDIssue: ClientIDIssue? {
        let value = trimmedClientID
        guard !value.isEmpty else { return nil }
        if value.contains(where: \.isWhitespace) { return .containsWhitespace }
        if value.contains("://") || value.lowercased().hasPrefix("http") { return .looksLikeURL }

        let invalid = value.filter { character in
            !(character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_"))
        }
        if !invalid.isEmpty {
            let listed = Set(invalid).sorted().map { "\u{201C}\($0)\u{201D}" }
            return .invalidCharacters(listed.joined(separator: ", "))
        }

        if value.count < 16 { return .tooShort(value.count) }
        if value.count > 64 { return .tooLong(value.count) }
        return nil
    }

    private var canConnect: Bool {
        !trimmedClientID.isEmpty && clientIDIssue == nil && !isAuthorizing
    }

    private var connectTitle: String {
        if isAuthorizing { return "Waiting for Oura\u{2026}" }
        return model.oura.hasAuthorization ? "Update Oura permissions" : "Continue with Oura"
    }

    // MARK: - Actions

    private func connect() {
        // Normalise before storing: a Client ID pasted with a trailing newline is the most
        // common way this flow fails, and it fails on Oura's side with an opaque message.
        clientID = trimmedClientID
        isAuthorizing = true
        Task {
            await model.oura.authorize(clientID: clientID)
            isAuthorizing = false
            if model.oura.status.isConnected { dismiss() }
        }
    }

    private func copyRedirectURI() {
        UIPasteboard.general.string = OuraOAuthSession.callbackURL.absoluteString
        didCopyRedirectURI = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyRedirectURI = false
        }
    }

    // MARK: - Row builders

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // The number is a circled glyph rather than a list marker, so VoiceOver would read
        // it as a bare digit ahead of an unrelated sentence. Say "Step 1" instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }

    private func permission(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    private func scopeTitle(_ scope: String) -> String {
        switch scope {
        case "daily": "Daily health"
        case "heartrate": "Heart rate"
        case "spo2Daily", "spo2": "Blood oxygen"
        case "stress": "Stress and resilience"
        case "heart_health": "Heart health"
        case "ring_configuration": "Ring details"
        case "personal": "Personal and ring"
        case "workout": "Workouts"
        case "session": "Sessions"
        case "tag": "Tags"
        default: scope
        }
    }
}
