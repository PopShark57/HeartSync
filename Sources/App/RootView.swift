import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.startupState {
        case .loading:
            ProgressView("Loading protected health history…")
                .accessibilityIdentifier("startup.loading")
        case .temporarilyUnavailable(let detail):
            StartupRecoveryView(detail: detail)
        case .ready:
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Now", systemImage: "waveform.path.ecg.rectangle") {
                DashboardView()
            }
            Tab("Oura", systemImage: "circle.circle.fill") {
                OuraDashboardView()
            }
            Tab("Compare", systemImage: "chart.xyaxis.line") {
                CompareView()
            }
            Tab("Devices", systemImage: "dot.radiowaves.left.and.right") {
                DevicesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tint(HeartSyncTheme.accent)
        .safeAreaInset(edge: .top) {
            if let notice = model.startupNotice {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("startup.notice")
                    Spacer(minLength: 8)
                    if model.settings.loadState == .failed {
                        Button("Retry") { Task { await model.retryStartup() } }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("settings.retry")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.18))
            }
        }
    }
}

private struct StartupRecoveryView: View {
    @Environment(AppModel.self) private var model
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("Health history temporarily unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                .accessibilityIdentifier("startup.unavailable")
        } description: {
            Text("HeartSync has not started Bluetooth, HealthKit, or Oura. Your existing files have not been overwritten. Unlock the device or resolve storage access, then retry.\n\n\(detail)")
        } actions: {
            Button("Retry") { Task { await model.retryStartup() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("startup.retry")
            ShareLink(item: "HeartSync startup diagnostics\n\(detail)") {
                Label("Share diagnostics", systemImage: "square.and.arrow.up")
            }
        }
        .padding()
    }
}
