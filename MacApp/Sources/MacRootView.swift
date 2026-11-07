import SwiftUI

/// The window: a sidebar of screens, with the sync state always visible at its foot.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @State private var screen: Screen? = .now
    @State private var confirmingFullCopy = false

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
                MacNowView { screen = .sync }
            case .compare:
                CompareView()
            case .devices:
                MacDevicesView()
            case .sync:
                MacSyncView { confirmingFullCopy = true }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SyncNowToolbarButton()
            }
        }
        .confirmationDialog(
            "Copy everything again from \(model.mirror.pairing?.peer.name ?? "the iPhone")?",
            isPresented: $confirmingFullCopy,
            titleVisibility: .visible
        ) {
            Button("Copy Everything Again") {
                screen = .sync
                model.mirror.copyEverythingAgain()
            }
        } message: {
            Text("The iPhone sends its whole history again, and anything it no longer has is removed from this Mac. What is here stays visible until the copy finishes. A long history can take a few minutes, with HeartSync open on the iPhone.")
        }
        .focusedSceneValue(\.heartSyncNavigate, { destination in screen = destination })
        .focusedSceneValue(\.heartSyncRequestFullCopy, model.mirror.canCopyEverythingAgain ? { confirmingFullCopy = true } : nil)
    }
}

/// Sync Now in the window's toolbar, or progress while the phone is sending.
private struct SyncNowToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mirror = model.mirror
        if mirror.connectedPhone != nil, mirror.progress.isSending {
            ProgressView()
                .controlSize(.small)
                .help("Receiving from the iPhone")
                .accessibilityLabel("Receiving from the iPhone")
        } else {
            Button {
                mirror.syncNow()
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .help("Reconnects to the iPhone, which then sends anything this Mac does not have yet.")
            .disabled(!mirror.canSyncNow)
            .accessibilityIdentifier("mac.toolbar.syncNow")
        }
    }
}

private extension Optional where Wrapped == MacMirrorProgress {
    /// A batch or snapshot is on its way, as opposed to waiting for the next change.
    var isSending: Bool {
        switch self {
        case .connecting, .snapshot, .catchingUp: true
        case .upToDate, nil: false
        }
    }
}

struct HeartSyncNavigationKey: FocusedValueKey {
    typealias Value = (MacRootView.Screen) -> Void
}

struct HeartSyncFullCopyKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var heartSyncNavigate: HeartSyncNavigationKey.Value? {
        get { self[HeartSyncNavigationKey.self] }
        set { self[HeartSyncNavigationKey.self] = newValue }
    }

    /// Asks to confirm a complete copy from the iPhone; nil while one cannot start.
    var heartSyncRequestFullCopy: HeartSyncFullCopyKey.Value? {
        get { self[HeartSyncFullCopyKey.self] }
        set { self[HeartSyncFullCopyKey.self] = newValue }
    }
}

/// The Sync menu: Sync Now, and a complete copy (which asks first).
struct HeartSyncSyncCommands: Commands {
    let mirror: MacMirrorService
    @FocusedValue(\.heartSyncRequestFullCopy) private var requestFullCopy

    var body: some Commands {
        CommandMenu("Sync") {
            Button("Sync Now") { mirror.syncNow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!mirror.canSyncNow)
            Button("Copy Everything Again from iPhone…") { requestFullCopy?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(requestFullCopy == nil)
        }
    }
}

struct HeartSyncNavigationCommands: Commands {
    @FocusedValue(\.heartSyncNavigate) private var navigate
    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(MacRootView.Screen.allCases.enumerated()), id: \.element.id) { index, screen in
                Button(screen.title) { navigate?(screen) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(navigate == nil)
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
                    // "Last synced 3 minutes ago" stays true while nothing else changes.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(detail(mirror))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
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
        if mirror.fullCopyRequested {
            return String(localized: "A complete copy starts when HeartSync is open on the iPhone.")
        }
        if let synced = mirror.lastSyncedAt {
            return String(localized: "Last synced \(synced.formatted(.relative(presentation: .named))). Open HeartSync on the iPhone to update.")
        }
        return String(localized: "Waiting for the iPhone. Open HeartSync on it, on the same network.")
    }
}
