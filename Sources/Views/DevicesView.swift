import SwiftUI

/// Setup and status for every data source: Bluetooth sensors, Apple Health, and Oura.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingScanner = false
    @State private var showingOuraSetup = false
    @State private var renamingSource: DataSource?

    var body: some View {
        NavigationStack {
            List {
                if model.store.sources.isEmpty {
                    Section {
                        EmptyStateView(
                            systemImage: "plus.circle.dashed",
                            title: "Add your first device",
                            message: "HeartSync reads from Bluetooth sensors directly, from Apple Health for your Apple Watch, and from the Oura Cloud API for your ring."
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                bluetoothSection
                appleHealthSection
                ouraSection

                if !estimateSources.isEmpty {
                    Section {
                        ForEach(estimateSources) { source in
                            SourceRow(source: source, statusText: "Computed by HeartSync", statusColor: .secondary)
                        }
                    } header: {
                        Text("Derived")
                    } footer: {
                        Text("Values HeartSync models rather than measures. They are excluded from disagreement analysis, since comparing a model against a sensor tells you about the model.")
                    }
                }
            }
            .navigationTitle("Devices")
            .sheet(isPresented: $showingScanner) { BluetoothScanView() }
            .sheet(isPresented: $showingOuraSetup) { OuraSetupView() }
            .sheet(item: $renamingSource) { source in
                RenameSourceView(source: source)
            }
        }
    }

    // MARK: Bluetooth

    private var bluetoothSources: [DataSource] {
        model.store.sources.filter { $0.transport == .bluetooth }
    }

    private var bluetoothSection: some View {
        Section {
            ForEach(bluetoothSources) { source in
                let state = model.bluetooth.connectionState(forSource: source.id)
                SourceRow(
                    source: source,
                    statusText: source.isEnabled ? state.title : "Paused",
                    statusColor: statusColor(for: state, enabled: source.isEnabled),
                    battery: source.batteryPercent,
                    hrvProgress: hrvProgressText(for: source)
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        model.removeSource(source)
                    } label: { Label("Remove", systemImage: "trash") }

                    Button {
                        renamingSource = source
                    } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.blue)
                }
                .contextMenu {
                    Button(source.isEnabled ? "Pause" : "Resume") {
                        model.store.setEnabled(!source.isEnabled, forSource: source.id)
                        if source.isEnabled {
                            model.bluetooth.disconnect(sourceID: source.id)
                        } else {
                            model.bluetooth.reconnect(sourceID: source.id)
                        }
                    }
                    Button("Reconnect") { model.bluetooth.reconnect(sourceID: source.id) }
                    Button("Rename") { renamingSource = source }
                    Button("Remove", role: .destructive) { model.removeSource(source) }
                }
            }

            Button {
                showingScanner = true
            } label: {
                Label("Add Bluetooth device", systemImage: "plus.circle.fill")
            }
            .disabled(!model.bluetooth.isPoweredOn)

            if !model.bluetooth.isPoweredOn {
                Text(model.bluetooth.stateDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Bluetooth sensors")
        } footer: {
            Text("Works with any device using the standard Bluetooth Heart Rate (0x180D), Pulse Oximeter (0x1822), or Health Thermometer (0x1809) profiles \u{2014} most chest straps, many rings, and standards-compliant pulse oximeters.")
        }
    }

    private func statusColor(for state: PeripheralConnectionState, enabled: Bool) -> Color {
        guard enabled else { return .secondary }
        switch state {
        case .streaming:                       return .green
        case .connecting, .discoveringServices:return .orange
        case .failed:                          return .red
        case .disconnected:                    return .secondary
        }
    }

    /// Shows progress towards the first HRV reading, which takes minutes of clean beats.
    private func hrvProgressText(for source: DataSource) -> String? {
        guard let uuid = UUID(uuidString: source.id),
              let progress = model.bluetooth.hrvProgress[uuid],
              progress.beats > 0,
              !source.observedMetrics.contains(.hrvRMSSD)
        else { return nil }
        return "Collecting beats for HRV \u{2014} \(progress.beats) of \(HRVMetrics.minimumBeats)"
    }

    // MARK: Apple Health

    private var healthSources: [DataSource] {
        model.store.sources.filter { $0.transport == .healthKit }
    }

    private var appleHealthSection: some View {
        Section {
            switch model.healthKit.availability {
            case .unavailable:
                Label("Health data is not available on this device", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

            case .notDetermined, .denied:
                Button {
                    Task {
                        await model.healthKit.requestAuthorization(
                            allowWriting: model.settings.snapshot.mirrorBluetoothToHealthKit
                        )
                        model.importProfileFromHealth()
                    }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.text.square.fill")
                }
                if case .denied = model.healthKit.availability, let error = model.healthKit.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

            case .authorized:
                ForEach(healthSources) { source in
                    SourceRow(
                        source: source,
                        statusText: source.model ?? "Via Apple Health",
                        statusColor: .secondary
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.removeSource(source) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                if healthSources.isEmpty {
                    Label("Connected \u{2014} waiting for samples", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
                Button {
                    Task { await model.healthKit.syncAll() }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                if let last = model.healthKit.lastSyncedAt {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Apple Watch data reaches HeartSync through Health \u{2014} the Watch is not a Bluetooth peripheral other apps can connect to. Every app or device writing to Health appears here as its own separate source, so nothing is silently merged.")
        }
    }

    // MARK: Oura

    private var ouraSection: some View {
        Section {
            if model.oura.status.isConnected {
                if let source = model.store.source(id: DataSource.ouraSourceID) {
                    SourceRow(
                        source: source,
                        statusText: model.oura.lastSyncSummary ?? "Connected",
                        statusColor: .green
                    )
                } else {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    Task { await model.oura.sync() }
                } label: {
                    Label(model.oura.isSyncing ? "Syncing\u{2026}" : "Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(model.oura.isSyncing)

                if let last = model.oura.lastSyncedAt {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.oura.endpointIssues.isEmpty {
                    Label(
                        "\(model.oura.endpointIssues.count) Oura collection\(model.oura.endpointIssues.count == 1 ? " is" : "s are") unavailable. The Oura tab shows permissions and details.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Button("Disconnect Oura", role: .destructive) {
                    if let source = model.store.source(id: DataSource.ouraSourceID) {
                        model.removeSource(source)
                    } else {
                        model.oura.disconnect()
                    }
                }
            } else {
                Button {
                    showingOuraSetup = true
                } label: {
                    Label("Connect Oura account", systemImage: "circle.circle.fill")
                }
                if case .error(let message) = model.oura.status {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Oura")
        } footer: {
            Text("Oura OAuth authorizes read-only Cloud API access. Data updates after the ring syncs with the Oura app, so it is not a live Bluetooth feed.")
        }
    }

    private var estimateSources: [DataSource] {
        model.store.sources.filter { $0.transport == .manual }
    }
}

/// One configured source in the list.
private struct SourceRow: View {
    var source: DataSource
    var statusText: String
    var statusColor: Color
    var battery: Int?
    var hrvProgress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                SourceDot(color: source.color, size: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let battery { BatteryBadge(percent: battery) }
            }

            if !source.observedMetrics.isEmpty {
                HStack(spacing: 5) {
                    ForEach(orderedMetrics, id: \.self) { kind in
                        Text(kind.shortTitle)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(kind.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(kind.tint)
                    }
                }
            }

            if let hrvProgress {
                Text(hrvProgress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var orderedMetrics: [MetricKind] {
        MetricKind.allCases.filter { source.observedMetrics.contains($0) }
    }
}

/// Rename sheet, so two identical rings can be told apart.
private struct RenameSourceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var source: DataSource
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    if let model = source.model {
                        Text("Reported as \(model)")
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            model.store.rename(sourceID: source.id, to: trimmed)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { name = source.displayName }
        }
    }
}
