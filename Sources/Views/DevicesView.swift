import SwiftUI

/// Setup and status for every data source: Bluetooth sensors, Apple Health, and Oura.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingScanner = false
    @State private var showingOuraSetup = false
    @State private var renamingSource: DataSource?
    /// A removal waiting for its confirmation. Nothing is deleted until the dialog's
    /// destructive button is pressed; a swipe or a menu item only proposes it.
    @State private var removal: RemovalProposal?
    @State private var exportPayload: ReadingsExportPayload?
    /// Held apart from `exportPayload`, which the sheet clears before `onDismiss` runs, so
    /// the temporary export is still known when the time comes to delete it.
    @State private var exportDirectory: URL?
    @State private var exportError: String?
    @State private var export = ReadingsExportJob()
    @State private var diagnosticsExport: DiagnosticsExportRequest?
    /// Why a removal, pause, or rename did not happen, so the list never claims a change
    /// that the database refused and that would revert at the next launch.
    @State private var changeFailure: String?

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
            .toolbarTitleDisplayMode(.inlineLarge)
            .heartSyncScreenBackground()
            .sheet(isPresented: $showingScanner) { BluetoothScanView() }
            .sheet(isPresented: $showingOuraSetup) { OuraSetupView() }
            .sheet(item: $renamingSource) { source in
                RenameSourceView(source: source)
            }
            // Attached to the list rather than to a row, swipe button, or menu item: those
            // are transient and can be gone before a dialog they own is presented.
            .confirmationDialog(
                removal?.consequence.title ?? "Remove device?",
                isPresented: Binding(
                    get: { removal != nil },
                    set: { if !$0 { removal = nil } }
                ),
                titleVisibility: .visible,
                presenting: removal
            ) { proposal in
                removalActions(proposal)
            } message: { proposal in
                Text(proposal.consequence.message)
            }
            .sheet(item: $diagnosticsExport) { request in
                DiagnosticsReportSheet(source: request.source)
            }
            .alert(
                "Change not saved",
                isPresented: Binding(
                    get: { changeFailure != nil },
                    set: { if !$0 { changeFailure = nil } }
                )
            ) {
                Button("OK", role: .cancel) { changeFailure = nil }
            } message: {
                Text(changeFailure ?? "")
            }
            .sheet(item: $exportPayload, onDismiss: discardExport) { payload in
                ReadingsShareSheet(items: [payload.url])
                    .ignoresSafeArea()
            }
            .alert(
                "Export failed",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "The export could not be prepared.")
            }
            .overlay {
                if export.isRunning {
                    ExportProgressRow(job: export)
                        .frame(maxWidth: 320)
                        .padding()
                        .background { HeartSyncCardBackground(cornerRadius: HeartSyncTheme.compactCornerRadius) }
                        .padding()
                }
            }
        }
    }

    // MARK: Removal

    /// The dialog's buttons. Deleting is one choice among several: exporting first and the
    /// two non-destructive alternatives sit beside it, because someone reaching for Remove
    /// often wants a noisy device gone from one comparison, not its history destroyed.
    @ViewBuilder
    private func removalActions(_ proposal: RemovalProposal) -> some View {
        Button(proposal.consequence.confirmTitle, role: .destructive) {
            confirmRemoval(proposal)
        }
        if proposal.consequence.offersExport, let source = proposal.source {
            Button("Export its readings first") { exportBeforeRemoval(source) }
        }
        if let source = proposal.source {
            if source.transport == .bluetooth, source.isEnabled {
                Button("Pause collecting instead") { setCollecting(false, source: source) }
            }
            if !isHiddenFromComparison(source) {
                Button("Hide from comparisons instead") {
                    model.settings.snapshot.setComparisonHidden(true, forSource: source.id)
                }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    /// Reads the numbers the dialog states. A failed count is passed on as unknown, which
    /// the wording reports as unknown rather than as "no readings".
    private func proposeRemoval(_ source: DataSource) {
        let history = model.store.sourceHistorySummaryOutcome(sourceID: source.id).value
        removal = RemovalProposal(
            source: source,
            consequence: .make(
                action: source.id == DataSource.ouraSourceID ? .disconnectOura : .removeSource,
                source: source,
                history: history
            )
        )
    }

    private func proposeOuraDisconnect() {
        if let source = model.store.source(id: DataSource.ouraSourceID) {
            proposeRemoval(source)
        } else {
            removal = RemovalProposal(
                source: nil,
                consequence: .make(action: .disconnectOura, source: nil, history: nil)
            )
        }
    }

    private func confirmRemoval(_ proposal: RemovalProposal) {
        removal = nil
        if let source = proposal.source {
            if case .failed(let detail) = model.removeSource(source) {
                changeFailure = "HeartSync could not remove \(source.displayName). Nothing was deleted. \(detail)"
            }
        } else {
            model.oura.disconnect()
        }
    }

    /// Writes this source's rows to a temporary CSV and opens the share sheet. The removal
    /// is not performed; the user comes back to Remove once the file is safe.
    ///
    /// Written off the main actor (`ReadingsExportJob`), with progress and Cancel.
    private func exportBeforeRemoval(_ source: DataSource) {
        removal = nil
        let filename = "HeartSync-\(Self.fileSafe(source.displayName))-readings.csv"
        export.start(history: model.store.history, sourceID: source.id, filename: filename) { result in
            switch result {
            case .success(let payload?):
                exportDirectory = payload.directory
                exportPayload = payload
            case .success(nil):
                exportError = "There are no stored readings from \(source.displayName) to export."
            case .failure(let error):
                exportError = "HeartSync could not export the readings. \(error.localizedDescription) Nothing was deleted or changed."
            }
        }
    }

    /// Removes the temporary export once the share sheet is gone, whatever the user did.
    private func discardExport() {
        if let exportDirectory {
            try? FileManager.default.removeItem(at: exportDirectory)
        }
        exportDirectory = nil
        exportPayload = nil
    }

    private func setCollecting(_ enabled: Bool, source: DataSource) {
        if case .failed(let detail) = model.store.setEnabled(enabled, forSource: source.id) {
            changeFailure = "HeartSync could not \(enabled ? "resume" : "pause") \(source.displayName). \(detail)"
            return
        }
        if enabled {
            model.bluetooth.reconnect(sourceID: source.id)
        } else {
            model.bluetooth.disconnect(sourceID: source.id)
        }
    }

    private static func fileSafe(_ name: String) -> String {
        let allowed = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "device" : collapsed
    }

    // MARK: Bluetooth

    private var bluetoothSources: [DataSource] {
        model.store.sources.filter { $0.transport == .bluetooth }
    }

    private var bluetoothSection: some View {
        Section {
            ForEach(bluetoothSources) { source in
                let state = model.bluetooth.connectionState(forSource: source.id)
                VStack(alignment: .leading, spacing: 6) {
                    SourceRow(
                        source: source,
                        statusText: source.isEnabled ? state.title : "Paused",
                        statusColor: statusColor(for: state, enabled: source.isEnabled),
                        battery: source.batteryPercent,
                        batteryIsCharging: source.batteryIsCharging ?? false,
                        hrvProgress: bluetoothDetailText(for: source)
                    )
                    .accessibilityIdentifier("source.\(source.id)")
                    if source.isEnabled, let ring = model.bluetooth.ringSession(forSource: source.id) {
                        ringControls(ring, source: source)
                        stressCheckResult(ring, source: source)
                    }
                }
                // No full swipe: with it, one long gesture performed Remove and deleted the
                // device's whole history, which for Bluetooth cannot be downloaded again.
                // Remove now only proposes; the dialog states what would be deleted.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        proposeRemoval(source)
                    } label: { Label("Remove", systemImage: "trash") }

                    Button {
                        renamingSource = source
                    } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.blue)
                }
                .contextMenu {
                    // Pause is a collection control: it disconnects the peripheral and
                    // stops new readings. Someone who only wants a noisy device out of one
                    // comparison wants the Sources menu on Compare instead, which changes
                    // nothing about the connection — the label says so rather than leaving
                    // them to discover the difference by losing data.
                    Button(source.isEnabled ? "Pause collecting" : "Resume collecting") {
                        setCollecting(!source.isEnabled, source: source)
                    }
                    if isHiddenFromComparison(source) {
                        Button("Show in comparisons") {
                            model.settings.snapshot.setComparisonHidden(false, forSource: source.id)
                        }
                    } else {
                        Button("Hide from comparisons") {
                            model.settings.snapshot.setComparisonHidden(true, forSource: source.id)
                        }
                    }
                    Button("Reconnect") { model.bluetooth.reconnect(sourceID: source.id) }
                    Button("Run Bluetooth diagnostics") {
                        model.bluetooth.runDiagnostics(sourceID: source.id)
                    }
                    .disabled(!model.bluetooth.isPoweredOn || !source.isEnabled)
                    if model.bluetooth.hasDiagnosticsReport(forSource: source.id) {
                        // Explicit export only. The report can contain raw packets from a
                        // diagnostic session, which are health data, so it is built when the
                        // user taps this rather than while the menu is being laid out.
                        Button {
                            diagnosticsExport = DiagnosticsExportRequest(source: source)
                        } label: {
                            Label("Export diagnostics\u{2026}", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Button("Rename") { renamingSource = source }
                    Button("Remove\u{2026}", role: .destructive) { proposeRemoval(source) }
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
            Text("Works with devices using the standard Bluetooth Heart Rate (0x180D), Pulse Oximeter (0x1822), or Health Thermometer (0x1809) profiles, such as most chest straps and standards-compliant pulse oximeters. Some rings only measure on request through a vendor protocol. HeartSync has candidate support for one such protocol (YCBT): once the ring has identified itself, it offers heart-rate, blood-oxygen, blood-pressure, and temperature measurements and a stress check, and can import the readings the ring stored on its own. The stress level is HeartSync's own estimate: the ring measures heart rate for it. Ring blood pressure and temperature are saved as estimates. Use Run Bluetooth diagnostics from a device's menu to see what it sends.")
        }
    }

    /// On-demand measurement and history import for a ring whose vendor protocol was
    /// identified. The ring does not measure continuously, so nothing starts without one of
    /// these explicit actions.
    @ViewBuilder
    private func ringControls(_ ring: R11MRingSession, source: DataSource) -> some View {
        if ring.isBusy {
            Button {
                model.bluetooth.cancelRingMeasurement(sourceID: source.id)
            } label: {
                Label(ring.isImportingHistory ? "Stop reading ring memory" : "Cancel measurement", systemImage: "stop.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .accessibilityHint(ring.isImportingHistory
                ? "Stops reading the ring's memory. Values already read stay saved."
                : "Asks the ring to stop measuring. Nothing from this measurement is saved.")
        } else if ring.canStartMeasurement {
            // One compact line: the three measurements share a menu, so the row stays the
            // height of a caption instead of wrapping four labelled buttons.
            HStack(spacing: 20) {
                Menu {
                    ForEach(R11MRingSession.Measurement.allCases, id: \.self) { measurement in
                        Button {
                            model.clearStressCheck(ringSourceID: source.id)
                            model.bluetooth.measure(measurement, sourceID: source.id)
                        } label: {
                            Label(measurement.menuTitle, systemImage: measurement.systemImage)
                        }
                        .accessibilityHint(measurementHint(measurement))
                    }
                    Divider()
                    Button {
                        model.checkStress(ringSourceID: source.id)
                    } label: {
                        Label("Stress level (estimate)", systemImage: MetricKind.stress.systemImage)
                    }
                    .accessibilityHint("Measures your heart rate on the ring, then estimates your stress level from it and from your recent HRV, breathing, temperature, and blood oxygen, compared with your own baseline.")
                } label: {
                    Label("Measure", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.medium))
                        .fixedSize()
                }
                // Takes the row's borderless button style, so only its label is a tap target.
                .menuStyle(.button)
                .accessibilityHint("Choose heart rate, blood oxygen, blood pressure, temperature, or a stress check for one on-demand measurement.")
                Button {
                    model.bluetooth.importRingHistory(sourceID: source.id)
                } label: {
                    Label("Import stored", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.medium))
                        .fixedSize()
                }
                .accessibilityHint("Reads the heart rate, blood oxygen, blood pressure, and temperature the ring recorded on its own. Nothing on the ring is changed or deleted.")
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
    }

    private func measurementHint(_ measurement: R11MRingSession.Measurement) -> String {
        switch measurement {
        case .heartRate:
            "Asks the ring for one heart-rate measurement. Keep the ring on your finger and still for about a minute."
        case .bloodOxygen:
            "Asks the ring for one blood-oxygen measurement. Keep your hand still for about a minute."
        case .bloodPressure:
            "Asks the ring for one blood-pressure value. A ring's value is a modelled estimate, not a cuff measurement."
        case .temperature:
            "Asks the ring for one temperature reading, then reads it from the ring's memory. A ring's finger temperature is saved as an estimate. Some rings have no temperature sensor and decline."
        }
    }

    /// The outcome of a stress check started from this ring, once the ring has measured.
    /// While the ring measures, its own status line already says so.
    @ViewBuilder
    private func stressCheckResult(_ ring: R11MRingSession, source: DataSource) -> some View {
        switch model.stressChecks[source.id] {
        case .measuring where ring.activeMeasurement == .heartRate:
            Label("Stress check: measuring heart rate first\u{2026}", systemImage: MetricKind.stress.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .scored(let assessment):
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Stress level \(MetricKind.stress.formatWithUnit(assessment.score)) \u{00B7} \(assessment.band.title)")
                } icon: {
                    Image(systemName: MetricKind.stress.systemImage)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MetricKind.stress.tint)
                if let drivers = assessment.driverSummary {
                    Text(drivers)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Estimate, not a measurement. See Now for details.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .unavailable(let reason):
            Label(StressModel.explanation(reason), systemImage: MetricKind.stress.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .measuring, nil:
            EmptyView()
        }
    }

    private func isHiddenFromComparison(_ source: DataSource) -> Bool {
        model.settings.snapshot.comparisonHidden.contains(source.id)
    }

    private func statusColor(for state: PeripheralConnectionState, enabled: Bool) -> Color {
        guard enabled else { return .secondary }
        switch state {
        case .streaming:                                              return .green
        case .connecting, .linkConnected, .discoveringServices,
             .enablingNotifications, .ready:                          return .orange
        case .unsupported, .subscriptionFailed, .streamStalled,
             .failed:                                                 return .red
        case .disconnected:                                           return .secondary
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

    private func bluetoothDetailText(for source: DataSource) -> String? {
        var details: [String] = []
        if let hrvProgress = hrvProgressText(for: source) {
            details.append(hrvProgress)
        }
        if let uuid = UUID(uuidString: source.id),
           let pulseOx = model.bluetooth.pulseOximeterQuality[uuid] {
            var quality = "Pulse ox: \(pulseOx.quality.title)"
            if !pulseOx.quality.reasons.isEmpty {
                quality += " (\(pulseOx.quality.reasons.map(\.title).joined(separator: ", ")))"
            }
            if let pai = pulseOx.pulseAmplitudeIndex {
                quality += " \u{00B7} perfusion index \(pai.formatted(.number.precision(.fractionLength(0...2))))"
            }
            if !pulseOx.quality.isDurable {
                quality += " \u{00B7} not saved"
            }
            details.append(quality)
        }
        return details.isEmpty ? nil : details.joined(separator: "\n")
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
                        statusText: healthSourceStatus(source),
                        statusColor: .secondary
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { proposeRemoval(source) } label: {
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
                    Text("Last complete sync \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }
                if let summary = model.healthKit.syncSummary {
                    Label(healthSyncStatus(summary), systemImage: healthSyncIcon(summary.outcome))
                        .font(.caption)
                        .foregroundStyle(summary.outcome == .complete ? .green : .orange)
                        .accessibilityIdentifier("healthkit.sync.status")
                    let details = summary.results.compactMap(\.userDetail)
                    if !details.isEmpty {
                        DisclosureGroup("Sync details") {
                            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Apple Watch data reaches HeartSync through Health. A Health source identifies its writing app when physical-device identity is unavailable; multiple reported device models are called out rather than silently treated as one instrument.")
        }
    }

    private func healthSourceStatus(_ source: DataSource) -> String {
        if source.hasMultipleReportedDevices {
            return source.model ?? "HealthKit writer with multiple reported devices"
        }
        if let model = source.model { return "HealthKit writer · \(model)" }
        return "HealthKit writer · physical device unknown"
    }

    private func healthSyncStatus(_ summary: HealthKitManager.HealthKitSyncSummary) -> String {
        switch summary.outcome {
        case .complete: "Complete"
        case .partial: "Partial: some data types were unavailable"
        case .failed: "Failed: no data type completed"
        case .permissionUnknown: "Permission unknown: Apple does not reveal read access"
        case .budgetDeferred: "More history remains; sync again to continue"
        }
    }

    private func healthSyncIcon(_ outcome: HealthKitManager.HealthKitSyncSummary.Outcome) -> String {
        switch outcome {
        case .complete: "checkmark.circle.fill"
        case .partial, .permissionUnknown, .budgetDeferred: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
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
                    let issueText = String(
                        localized: "devices.oura.issues",
                        defaultValue: "\(model.oura.endpointIssues.count) Oura collections need attention: unavailable or incomplete. The Oura tab shows permissions and details.",
                        comment: "Warning on the Devices list. The argument is how many Oura collections have a problem."
                    )
                    Label(issueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Warning. \(issueText)")
                }

                Button("Disconnect Oura", role: .destructive) {
                    proposeOuraDisconnect()
                }
                .accessibilityHint("Asks before removing the Oura authorization and its readings from this device")
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

/// A removal the user has asked for but not yet confirmed.
private struct RemovalProposal: Identifiable {
    /// Nil only for disconnecting an Oura account that has not stored anything yet.
    var source: DataSource?
    var consequence: SourceRemovalConsequence

    var id: String { source?.id ?? "oura.disconnect" }
}

/// One configured source in the list.
private struct SourceRow: View {
    var source: DataSource
    var statusText: String
    var statusColor: Color
    var battery: Int?
    var batteryIsCharging = false
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
                if let battery { BatteryBadge(percent: battery, isCharging: batteryIsCharging) }
            }

            if !source.observedMetrics.isEmpty {
                // Wraps instead of overflowing: a Health writer can report seven metrics,
                // which does not fit one line at a compact width and large text.
                FlowLayout(spacing: 5, lineSpacing: 5) {
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

    /// Placement and independently known technology are separate facts. Body Sensor
    /// Location never proves PPG or ECG.
    private var placementText: String? {
        let facts = [source.bodyLocation?.title, source.sensingTechnology?.title].compactMap { $0 }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
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
        if let battery { parts.append(BatteryBadge.spoken(percent: battery, isCharging: batteryIsCharging)) }
        if let location = source.bodyLocation {
            parts.append("Reported placement \(location.title.lowercased())")
        }
        if let technology = source.sensingTechnology {
            parts.append("Reported technology \(technology.title)")
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
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name", text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let model = source.model {
                            Text("Reported as \(model)")
                        }
                        if let failure {
                            Text(failure).foregroundStyle(.red)
                        }
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
                            if case .failed(let detail) = model.store.rename(sourceID: source.id, to: trimmed) {
                                failure = "HeartSync could not save the new name. \(detail)"
                                return
                            }
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { name = source.displayName }
        }
    }
}

/// A request to show one device's diagnostics report.
private struct DiagnosticsExportRequest: Identifiable {
    var source: DataSource
    var id: String { source.id }
}

/// The report for one device, built when this sheet appears rather than while the device
/// list is laid out. It can contain raw packets from a diagnostic session, which are health
/// data, so it goes nowhere unless the user shares it.
private struct DiagnosticsReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var source: DataSource
    @State private var report: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report ?? "This device has no diagnostics for its current connection.")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let report {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: report,
                            preview: SharePreview("Bluetooth diagnostics for \(source.displayName)")
                        )
                    }
                }
            }
            .task {
                report = model.bluetooth.diagnosticsReport(
                    forSource: source.id,
                    deviceName: source.displayName
                )
            }
        }
    }
}
