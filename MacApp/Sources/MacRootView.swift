import SwiftUI

/// The window: a sidebar of screens, with the sync state always visible at its foot.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @State private var screen: Screen? = .now

    enum Screen: String, Hashable, CaseIterable, Identifiable {
        case now
        case compare
        case devices
        case sync

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .now: "Now"
            case .compare: "Compare"
            case .devices: "Devices"
            case .sync: "iPhone Sync"
            }
        }

        var systemImage: String {
            switch self {
            case .now: "waveform.path.ecg.rectangle"
            case .compare: "chart.xyaxis.line"
            case .devices: "dot.radiowaves.left.and.right"
            case .sync: "iphone.and.arrow.forward"
            }
        }
    }

    var body: some View {
        switch model.startupState {
        case .loading:
            ProgressView("Opening the mirrored history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .temporarilyUnavailable(let detail):
            ContentUnavailableView {
                Label("Mirrored history unavailable", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(detail)
            } actions: {
                Button("Retry") { Task { await model.start() } }
                    .heartSyncButtonStyle(prominent: true)
            }
        case .ready:
            split
        }
    }

    private var split: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { screen in
                Label(screen.title, systemImage: screen.systemImage)
                    .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                MirrorStatusFooter { screen = .sync }
                    .padding(10)
            }
        } detail: {
            switch screen ?? .now {
            case .now:
                MacNowView()
            case .compare:
                CompareView()
            case .devices:
                MacDevicesView()
            case .sync:
                MacSyncView()
            }
        }
    }
}

/// Where the mirror stands, in one line under the sidebar: whose history this is and how
/// fresh, so no screen can be mistaken for a live view of the devices.
private struct MirrorStatusFooter: View {
    @Environment(AppModel.self) private var model
    var openSync: () -> Void

    var body: some View {
        let mirror = model.mirror
        Button(action: openSync) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(detail(mirror))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { HeartSyncCardBackground(tint: tint, cornerRadius: HeartSyncTheme.compactCornerRadius) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows iPhone sync")
    }

    private var title: String {
        let mirror = model.mirror
        guard let pairing = mirror.pairing else { return String(localized: "Not paired") }
        return mirror.connectedPhone ?? pairing.peer.name
    }

    private var symbol: String {
        let mirror = model.mirror
        if mirror.pairing == nil { return "iphone.slash" }
        if mirror.connectedPhone != nil { return "iphone.radiowaves.left.and.right" }
        return "iphone"
    }

    private var tint: Color {
        let mirror = model.mirror
        if mirror.pairing == nil { return .secondary }
        if mirror.issue != nil { return .orange }
        return mirror.connectedPhone != nil ? .green : .secondary
    }

    private func detail(_ mirror: MacMirrorService) -> String {
        guard mirror.pairing != nil else {
            return String(localized: "Pair with your iPhone to see its history here.")
        }
        if mirror.connectedPhone != nil {
            switch mirror.progress {
            case .snapshot(let sent, let total):
                return String(localized: "Copying history: \(sent.formatted()) of \(total.formatted())")
            case .catchingUp, .connecting:
                return String(localized: "Receiving changes…")
            case .upToDate, nil:
                return String(localized: "Connected · up to date")
            }
        }
        if let synced = mirror.lastSyncedAt {
            return String(localized: "Last synced \(synced.formatted(.relative(presentation: .named))). Open HeartSync on the iPhone to update.")
        }
        return String(localized: "Waiting for the iPhone. Open HeartSync on it, on the same network.")
    }
}
