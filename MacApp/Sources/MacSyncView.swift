import SwiftUI

/// Pairing with the iPhone, and how the mirror stands.
struct MacSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingUnpair = false
    @State private var unpairFailed = false

    var body: some View {
        let mirror = model.mirror
        NavigationStack {
            Form {
                if mirror.pairingUnavailable {
                    Section {
                        Label("The pairing could not be read from the Keychain.", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Button("Try Again") { mirror.retryKeychain() }
                    }
                }
                if let pairing = mirror.pairing {
                    pairedSection(pairing, mirror: mirror)
                }
                pairingSection(mirror)
                Section("How it works") {
                    Text("HeartSync on the iPhone sends this Mac a copy of its history whenever it is open there and both are on the same network. The copy is read-only: devices, imports, and deletions are managed on the iPhone, and anything it deletes is deleted here too.")
                    Text("The connection goes directly between the two devices, encrypted with a key made when they paired. Nothing passes through a server or iCloud.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("iPhone Sync")
            .confirmationDialog(
                "Unpair \(mirror.pairing?.peer.name ?? "the iPhone")?",
                isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button("Unpair and Delete the Copy", role: .destructive) {
                    unpairFailed = !mirror.unpair()
                }
            } message: {
                Text("The iPhone's history is deleted from this Mac. Nothing on the iPhone is deleted, and you can pair again later to copy it back.")
            }
            .alert("The pairing could not be removed", isPresented: $unpairFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The Keychain could not be updated. Try again.")
            }
        }
    }

    @ViewBuilder
    private func pairedSection(_ pairing: MacMirrorPairingRecord, mirror: MacMirrorService) -> some View {
        Section("Paired iPhone") {
            LabeledContent("iPhone") {
                Text(pairing.peer.name)
            }
            LabeledContent("Status") {
                Text(status(mirror))
                    .foregroundStyle(mirror.connectedPhone != nil ? .primary : .secondary)
            }
            if case .snapshot(let sent, let total) = mirror.progress, total > 0 {
                ProgressView(value: Double(sent), total: Double(total)) {
                    Text("Copying history")
                } currentValueLabel: {
                    Text("\(sent.formatted()) of \(total.formatted()) readings")
                }
            }
            if let synced = mirror.lastSyncedAt {
                LabeledContent("Last synced") {
                    Text(synced, format: .relative(presentation: .named))
                }
            }
            LabeledContent("Mirrored readings") {
                Text(model.store.readingCountOutcome.value.map { $0.formatted() } ?? "—")
                    .monospacedDigit()
            }
            LabeledContent("Paired") {
                Text(pairing.pairedAt, format: .dateTime.year().month().day())
            }
            if let issue = mirror.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Button("Unpair…", role: .destructive) { confirmingUnpair = true }
        }
    }

    @ViewBuilder
    private func pairingSection(_ mirror: MacMirrorService) -> some View {
        Section(mirror.pairing == nil ? "Pair with iPhone" : "Pair a Different iPhone") {
            switch mirror.pairingPhase {
            case .closed:
                Text(mirror.pairing == nil
                     ? "Pair once, and this Mac keeps a copy of the iPhone's HeartSync history."
                     : "Pairing another iPhone deletes this copy and starts again with that iPhone's history.")
                    .foregroundStyle(.secondary)
                Button("Pair with iPhone…") { mirror.openPairingWindow() }
                    .heartSyncButtonStyle(prominent: mirror.pairing == nil)
            case .waiting:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the iPhone. On the iPhone, open HeartSync › Settings › Mac › Pair a Mac, and choose \(mirror.macName).")
                }
                Button("Cancel") { mirror.closePairingWindow() }
            case .comparing(let code, let phone):
                codeView(code: code, phone: phone)
                HStack {
                    Button("They Don't Match") { mirror.answer(false) }
                    Button("They Match") { mirror.answer(true) }
                        .heartSyncButtonStyle(prominent: true)
                        .keyboardShortcut(.defaultAction)
                }
            case .waitingForPhone(let code, let phone):
                codeView(code: code, phone: phone)
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Confirm on the iPhone too.")
                }
            case .paired(let name):
                Label("Paired with \(name). Its history is being copied.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { mirror.closePairingWindow() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Try Again") {
                        mirror.closePairingWindow()
                        mirror.openPairingWindow()
                    }
                    Button("Cancel") { mirror.closePairingWindow() }
                }
            }
        }
    }

    private func codeView(code: String, phone: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check that \(phone) shows the same code")
                .font(.headline)
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .textSelection(.disabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text("If the codes are different, choose They Don't Match. Something else on the network may be trying to pair.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func status(_ mirror: MacMirrorService) -> String {
        if mirror.connectedPhone != nil {
            switch mirror.progress {
            case .snapshot: return String(localized: "Connected · copying history")
            case .catchingUp, .connecting: return String(localized: "Connected · receiving changes")
            case .upToDate, nil: return String(localized: "Connected · up to date")
            }
        }
        return String(localized: "Not connected. Open HeartSync on the iPhone, on the same network.")
    }
}

/// HeartSync › Settings: this Mac's display choices.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Flag disagreements at", selection: $settings.snapshot.discrepancyThreshold) {
                Text("Notable and above").tag(DiscrepancySeverity.notable)
                Text("Major only").tag(DiscrepancySeverity.major)
                Text("Everything").tag(DiscrepancySeverity.agreeing)
            }
            Text("Applies to this Mac's comparison screens only. Devices hidden from comparisons here stay visible on the iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .disabled(model.settings.loadState == .failed)
    }
}
