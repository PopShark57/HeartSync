import SwiftUI

/// Settings › Mac: paired Macs, their sync state, pairing, and forgetting.
struct MacSyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pairing: MacMirrorPairingClient?
    @State private var forgetting: MacMirrorPairingRecord?
    @State private var forgetFailed = false

    var body: some View {
        let mirror = model.macMirror
        Form {
            if let issue = mirror.discoveryIssue {
                Section {
                    Label(issue, systemImage: "network.slash")
                    Text("Check Wi-Fi and HeartSync's Local Network access in Settings.")
                        .font(.caption)
                    Button("Retry discovery") { mirror.retryDiscovery() }
                }
            }
            if mirror.pairingsUnavailable {
                Section {
                    Label("Paired Macs can't be read until the iPhone is unlocked.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                if mirror.pairings.isEmpty {
                    Text("No Mac is paired.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mirror.pairings) { record in
                    MacSyncRow(record: record, status: mirror.status[record.identity])
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Forget", role: .destructive) { forgetting = record }
                        }
                        .contextMenu {
                            Button("Forget This Mac", systemImage: "trash", role: .destructive) { forgetting = record }
                        }
                }
                Button("Pair a Mac", systemImage: "plus") {
                    pairing = MacMirrorPairingClient(publisher: mirror)
                }
                .accessibilityIdentifier("mac.pair")
            } header: {
                Text("Macs")
            } footer: {
                Text("Open HeartSync on the Mac and choose Pair with iPhone. The Mac keeps a read-only copy of your history and updates while HeartSync is open on this iPhone and both are on the same network. It is sent encrypted, directly between the two devices, and never through a server.")
            }
        }
        .navigationTitle("Mac")
        .navigationBarTitleDisplayMode(.inline)
        .heartSyncScreenBackground()
        .sheet(item: $pairing) { client in
            MacPairingSheet(client: client)
        }
        .confirmationDialog(
            "Forget \(forgetting?.peer.name ?? "this Mac")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { record in
            Button("Forget Mac", role: .destructive) {
                forgetFailed = !mirror.forget(record)
            }
        } message: { _ in
            Text("This iPhone stops sending to the Mac. The copy already on the Mac stays there until you unpair it on the Mac. Nothing on this iPhone is deleted.")
        }
        .alert("The Mac could not be forgotten", isPresented: $forgetFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Keychain could not be updated. Unlock the iPhone and try again.")
        }
    }
}

extension MacMirrorPairingClient: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct MacSyncRow: View {
    let record: MacMirrorPairingRecord
    let status: MacMirrorPublisher.PeerStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(record.peer.name, systemImage: "desktopcomputer")
                .font(.body.weight(.semibold))
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = status?.issue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        switch status?.progress {
        case .connecting:
            return String(localized: "mac.status.connecting", defaultValue: "Connecting…", comment: "Mac sync status")
        case .snapshot(let sent, let total):
            return String(localized: "mac.status.snapshot", defaultValue: "Sending history: \(sent.formatted()) of \(total.formatted()) readings", comment: "Mac sync status during the first full copy")
        case .catchingUp:
            return String(localized: "mac.status.catchingUp", defaultValue: "Sending changes…", comment: "Mac sync status")
        case .upToDate:
            return String(localized: "mac.status.upToDate", defaultValue: "Up to date", comment: "Mac sync status")
        case nil:
            if status?.isReachable == false || status == nil {
                if let synced = status?.lastSyncedAt {
                    return String(localized: "mac.status.notFound.synced", defaultValue: "Not on this network · last synced \(synced.formatted(.relative(presentation: .named)))", comment: "Mac sync status: Mac not found; when it last synced")
                }
                return String(localized: "mac.status.notFound", defaultValue: "Not on this network · open HeartSync on the Mac", comment: "Mac sync status: Mac not found")
            }
            return String(localized: "mac.status.waiting", defaultValue: "Waiting to connect", comment: "Mac sync status")
        }
    }
}

/// Finds Macs waiting to pair, then shows the code to compare.
private struct MacPairingSheet: View {
    let client: MacMirrorPairingClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch client.phase {
                case .searching:
                    searching
                case .connecting(let name):
                    ProgressView("Connecting to \(name)…")
                case .comparing(let code, let mac):
                    comparison(code: code, mac: mac, waiting: false)
                case .waitingForMac(let code, let mac):
                    comparison(code: code, mac: mac, waiting: true)
                case .paired(let name):
                    ContentUnavailableView {
                        Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Your history is being copied to the Mac. Keep HeartSync open on this iPhone until the Mac says it is up to date.")
                    } actions: {
                        Button("Done") { dismiss() }
                            .heartSyncButtonStyle(prominent: true)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Pairing didn't finish", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { client.tryAgain() }
                            .heartSyncButtonStyle(prominent: true)
                    }
                }
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { client.start() }
        .onDisappear { client.stop() }
    }

    private var searching: some View {
        List {
            Section {
                if client.found.isEmpty {
                    HStack(spacing: 12) {
                        if client.discovery == .searching { ProgressView() }
                        Text(client.discovery == .searching ? "Looking for Macs…" : "No Macs found yet")
                            .foregroundStyle(.secondary)
                    }
                }
                if case .unavailable(let detail) = client.discovery {
                    Label(detail, systemImage: "network.slash")
                    Text("Check Wi-Fi and Local Network access for HeartSync in Settings. This error can also mean the network is unavailable.")
                        .font(.caption)
                }
                if client.discovery != .searching {
                    Button("Search Again") { client.tryAgain() }
                }
                ForEach(client.found) { mac in
                    Button {
                        client.pair(with: mac)
                    } label: {
                        Label(mac.name, systemImage: "desktopcomputer")
                    }
                }
            } footer: {
                Text("On the Mac, open HeartSync and choose Pair with iPhone. It appears here while it is waiting. Both devices must be on the same network.")
            }
        }
    }

    private func comparison(code: String, mac: String, waiting: Bool) -> some View {
        VStack(spacing: 20) {
            Text("Check that \(mac) shows the same code")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("mac.pairingCode")
            if waiting {
                ProgressView("Confirm on the Mac too")
            } else {
                Text("If the codes are different, choose They Don't Match. Something else on the network may be trying to pair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("They Don't Match", role: .cancel) { client.answer(false) }
                        .heartSyncButtonStyle()
                    Button("They Match") { client.answer(true) }
                        .heartSyncButtonStyle(prominent: true)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
