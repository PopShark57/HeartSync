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
            .accessibilityHint("Opens a scan for nearby heart-rate, pulse-oximeter, and thermometer sensors")

            if !model.bluetooth.isPoweredOn {
                Text(model.bluetooth.stateDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    // Orange is the only visual carrier of "this is a problem"; say it.
                    .accessibilityLabel("Bluetooth unavailable. \(model.bluetooth.stateDescription)")
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
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Health authorization problem. \(error)")
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
                .accessibilityHint("Re-reads recent samples from Apple Health")
                if let last = model.healthKit.lastSyncedAt {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
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
                // The client-side OAuth flow issues no refresh token, so the credential
                // expires outright. Warn here rather than letting the next sync fail first.
                let expiry = OuraAuthorizationExpiry(expiresAt: model.oura.authorizationExpiresAt)
                if let message = expiry.message {
                    Button {
                        showingOuraSetup = true
                    } label: {
                        Label(message, systemImage: expiry.systemImage)
                            .font(.subheadline)
                    }
                    .foregroundStyle(expiry.tint)
                    .accessibilityLabel(message)
                    .accessibilityHint("Opens Oura sign-in so you can authorize HeartSync again")
                }

                Button {
                    Task { await model.oura.sync() }
                } label: {
                    Label(model.oura.isSyncing ? "Syncing\u{2026}" : "Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(model.oura.isSyncing)
                .accessibilityHint("Fetches the most recent two weeks of Oura Cloud data")

                if let last = model.oura.lastSyncedAt {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }

                if !model.oura.endpointIssues.isEmpty {
                    // Not "unavailable": an endpoint issue can also be a collection that
                    // imported only a prefix. The Oura tab distinguishes the two.
                    let issueText = "\(model.oura.endpointIssues.count) Oura collection\(model.oura.endpointIssues.count == 1 ? " needs" : "s need") attention: unavailable or incomplete. The Oura tab shows permissions and details."
                    Label(issueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Warning. \(issueText)")
                }

                Button("Disconnect Oura", role: .destructive) {
                    if let source = model.store.source(id: DataSource.ouraSourceID) {
                        model.removeSource(source)
                    } else {
                        model.oura.disconnect()
                    }
                }
                .accessibilityHint("Removes the Oura authorization and its readings from this device")
            } else {
                Button {
                    showingOuraSetup = true
                } label: {
                    Label("Connect Oura account", systemImage: "circle.circle.fill")
                }
                .accessibilityHint("Opens the one-time Oura setup and sign-in")
                if case .error(let message) = model.oura.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Oura error. \(message)")
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

            if let placement = placementText {
                Text(placement)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let hrvProgress {
                Text(hrvProgress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var orderedMetrics: [MetricKind] {
        MetricKind.allCases.filter { source.observedMetrics.contains($0) }
    }

    /// Where the sensor sits and what technology that implies, when the device reported
    /// Body Sensor Location (0x2A38).
    ///
    /// Shown because it is the field that explains *why* two devices disagree rather than
    /// just that they do: an optical (PPG) ring and an electrical (ECG) chest strap are not
    /// measuring the same signal, so an HRV gap between them is expected rather than a
    /// fault. Nil for every source that does not report the characteristic — which is most
    /// of them, including everything arriving via Apple Health or the Oura Cloud API — and
    /// the row simply omits the line in that case rather than guessing a placement.
    private var placementText: String? {
        guard let location = source.bodyLocation else { return nil }
        return "\(location.title) \u{00B7} \(location.sensingTechnology)"
    }

    /// One VoiceOver element for the whole row.
    ///
    /// Visually this row is a compound of colour dot, status dot, name, status text,
    /// battery pill, sensor placement, metric chips, and HRV progress. Read as separate
    /// children it becomes a stream of unrelated fragments ("RHR", "SpO2", "78%"), and both
    /// dots carry meaning only as colour, which VoiceOver cannot convey at all. Children are
    /// therefore ignored in favour of one composed sentence that restates the status in
    /// words and spells out each metric chip with its full `MetricKind.title` rather than
    /// the abbreviation the chip shows.
    private var accessibilityDescription: String {
        var parts: [String] = [source.displayName, statusText]
        if let battery { parts.append("Battery \(battery) percent") }
        if let location = source.bodyLocation {
            parts.append("Worn on the \(location.title.lowercased()), \(location.sensingTechnology) sensor")
        }
        if !orderedMetrics.isEmpty {
            parts.append("Reports \(orderedMetrics.map(\.title).joined(separator: ", "))")
        }
        if let hrvProgress { parts.append(hrvProgress) }
        return parts.joined(separator: ". ")
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
