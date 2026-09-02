import SwiftUI

/// Authorization state, the requested OAuth scopes, and the screen's standing limitations.
///
/// Permission display is deliberately server-authoritative. Oura decides what a token may
/// read; when the callback carried no scope metadata this section says "Checked by Oura"
/// rather than claiming a scope was denied, and it never blocks a collection locally.
///
/// The three closing rows are the Oura tab's honesty contract — on-device token storage,
/// cloud timing ("not a live feed"), and the absence of raw accelerometer samples. They are
/// not decorative and must not be softened, shortened, or made conditional.
struct OuraOAuthSection: View {
    var hasAuthorization: Bool
    var expiresAt: Date?
    /// Nil means Oura reported no scope metadata, not that every scope was denied.
    var grantedScopes: Set<String>?
    var onManagePermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "OAuth & data access",
                subtitle: "What HeartSync can ask Oura to share",
                systemImage: "key.fill"
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasAuthorization ? "Oura authorization saved" : "Authorization needed")
                            .font(.headline)
                        if let expiresAt {
                            Text("Expires \(expiresAt.formatted(.relative(presentation: .named))) · \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Connect again to refresh this cached dashboard.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: hasAuthorization ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(hasAuthorization ? .green : .orange)
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text("Permissions")
                        .font(.subheadline.weight(.semibold))
                    ForEach(OuraOAuthSession.requestedScopes, id: \.self) { scope in
                        OuraScopeRow(scope: scope, state: scopeState(scope))
                    }
                }

                Button {
                    onManagePermissions()
                } label: {
                    Label(hasAuthorization ? "Update permissions" : "Reconnect Oura", systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    OuraHonestInfoRow(
                        icon: "lock.shield.fill",
                        tint: .green,
                        title: "On-device privacy",
                        message: "The access token stays in the device-only Keychain. Dashboard records are cached locally and are not sent to a HeartSync server."
                    )
                    OuraHonestInfoRow(
                        icon: "icloud.and.arrow.down",
                        tint: .blue,
                        title: "Cloud timing",
                        message: "This is the latest data Oura has processed—not a live feed. Sleep and readiness may require opening the Oura app and syncing the ring."
                    )
                    OuraHonestInfoRow(
                        icon: "waveform.path",
                        tint: .orange,
                        title: "Movement limits",
                        message: "The public API provides processed movement classes, MET values, and session motion counts. It does not expose raw accelerometer samples."
                    )
                }
            }
            .ouraCard()
        }
    }

    /// `spo2Daily` and `spo2` are recognised aliases for the same permission; either name
    /// counts as granted.
    private func scopeState(_ scope: String) -> OuraPermissionDisplayState {
        guard hasAuthorization else { return .missing }
        guard let granted = grantedScopes else { return .unknown }
        if scope == "spo2Daily" || scope == "spo2" {
            return granted.contains("spo2Daily") || granted.contains("spo2") ? .granted : .missing
        }
        return granted.contains(scope) ? .granted : .missing
    }
}
