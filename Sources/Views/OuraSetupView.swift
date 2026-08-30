import SwiftUI

/// Oura connection sheet. Authentication happens in an ASWebAuthenticationSession; the
/// app receives a scoped OAuth access token and stores it in the device-only keychain.
struct OuraSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// An OAuth client ID is public configuration, not a client secret. Keeping it in app
    /// preferences lets personal builds connect without compiling credentials into source.
    @AppStorage("oura.oauth.client-id") private var clientID = ""
    @State private var isAuthorizing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("HeartSync connects through Oura OAuth. You sign in on Oura's site and choose which read-only data to share; HeartSync never sees your password.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !model.oura.missingRequestedScopes.isEmpty {
                    Section {
                        Label(
                            "Your current authorization is missing \(model.oura.missingRequestedScopes.map(scopeTitle).joined(separator: ", ")). Continue below and enable those permissions on Oura's consent screen.",
                            systemImage: "lock.trianglebadge.exclamationmark"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    } header: {
                        Text("Update permissions")
                    }
                }

                Section("One-time setup") {
                    step(1, "Open Oura API Applications and create an OAuth application.")
                    step(2, "Add this exact redirect URI to the application:")

                    Text(OuraOAuthSession.callbackURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    step(3, "Copy the application's Client ID and paste it below.")

                    Button {
                        openURL(OuraOAuthSession.applicationPortalURL)
                    } label: {
                        Label("Open Oura API Applications", systemImage: "safari")
                    }
                }

                Section {
                    TextField("Oura Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("OAuth Client ID")
                } footer: {
                    Text("The Client ID identifies your OAuth application and is not secret. Do not enter or embed the Client Secret; HeartSync's client-side OAuth flow does not use it.")
                }

                if case .error(let message) = model.oura.status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            if isAuthorizing { ProgressView().controlSize(.small) }
                            Text(isAuthorizing
                                ? "Waiting for Oura\u{2026}"
                                : (model.oura.hasAuthorization ? "Update Oura permissions" : "Continue with Oura"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthorizing)
                }

                Section {
                    permission("Daily health", "Sleep, activity, readiness, and daily recovery summaries")
                    permission("Heart rate", "Five-minute heart-rate samples after the ring syncs")
                    permission("Blood oxygen", "Nightly SpO₂ and breathing-disturbance summaries")
                    permission("Stress & resilience", "Daily stress, recovery, and resilience signals")
                    permission("Heart health", "Cardiovascular age and VO₂ max")
                    permission("Personal and ring", "Profile, ring configuration, and battery")
                    permission("Workouts, sessions, and tags", "Your activity timeline and Oura-processed motion counts")
                } header: {
                    Text("Requested read-only access")
                } footer: {
                    Text("You can decline individual permissions. HeartSync will keep the account connected and mark only that data unavailable. The OAuth token stays in this device's Keychain; the client-side flow requires authorization again after it expires.")
                }
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

    private func connect() {
        isAuthorizing = true
        Task {
            await model.oura.authorize(clientID: clientID)
            isAuthorizing = false
            if model.oura.status.isConnected { dismiss() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func permission(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
