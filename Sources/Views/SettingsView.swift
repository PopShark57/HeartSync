import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCalibration = false
    @State private var retentionSelection = 30
    @State private var retentionProposal: RetentionProposal?
    @State private var resetProposal: ResetProposal?
    @State private var persistenceResult: String?
    @State private var mirrorWriteAlert: MirrorWriteAlert?

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
                if model.settings.loadState == .failed {
                    Section {
                        Label("Settings are temporarily read-only", systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("settings.unavailable")
                        Text(model.settings.loadIssue ?? "The settings archive is unavailable. Existing bytes were preserved.")
                            .font(.caption)
                        Button("Retry settings") { Task { await model.retryStartup() } }
                    }
                }
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        LabeledContent("Profile") {
                            Text(profileSummary).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("You")
                } footer: {
                    Text("Age is used only for the age-predicted maximum heart rate that the VO\u{2082} max estimate depends on.")
                }
                .disabled(settingsUnavailable)

                Section {
                    Toggle("Estimate VO\u{2082} max", isOn: $settings.snapshot.vo2MaxEstimateEnabled)
                } header: {
                    Text("VO\u{2082} max")
                } footer: {
                    Text("For devices that report resting heart rate but not VO\u{2082} max, HeartSync estimates it as 15.3 \u{00D7} (max HR \u{00F7} resting HR), the Uth\u{2013}S\u{00F8}rensen formula. Its error is roughly 10\u{2013}15%, far wider than the difference between two real measurements, so estimates are marked as such and left out of disagreement analysis.")
                }
                .disabled(settingsUnavailable)

                bloodPressureSection
                    .disabled(settingsUnavailable)

                Section {
                    Picker("Flag disagreements at", selection: $settings.snapshot.discrepancyThreshold) {
                        Text("Notable and above").tag(DiscrepancySeverity.notable)
                        Text("Major only").tag(DiscrepancySeverity.major)
                        Text("Everything").tag(DiscrepancySeverity.agreeing)
                    }
                } header: {
                    Text("Comparison")
                } footer: {
                    Text(toleranceSummary)
                }
                .disabled(settingsUnavailable)

                Section {
                    Toggle("Auto-sync Oura", isOn: $settings.snapshot.autoSyncOura)
                    Toggle("Write Bluetooth data to Health", isOn: $settings.snapshot.mirrorBluetoothToHealthKit)
                } header: {
                    Text("Syncing")
                } footer: {
                    Text("Writing to Health shares readings from your Bluetooth sensors with your other apps. Only directly measured values are written \u{2014} nothing HeartSync estimated ever enters your health record.")
                }
                .disabled(settingsUnavailable)

                Section {
                    Picker("Keep readings for", selection: Binding(
                        get: { retentionSelection },
                        set: { proposeRetention($0) }
                    )) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    LabeledContent("Stored readings") {
                        Text("\(model.store.readingCount)").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Button("Clear local cache; data may resync", role: .destructive) {
                        resetProposal = .clearForResync
                    }
                    .accessibilityIdentifier("data.clearForResync")
                    Button("Forget imported history", role: .destructive) {
                        resetProposal = .forgetImportedHistory
                    }
                    .accessibilityIdentifier("data.forgetHistory")
                } header: {
                    Text("Data")
                } footer: {
                    Text(retentionFooter)
                }
                .disabled(settingsUnavailable)

                Section {
                    NavigationLink("How each metric is obtained") { MetricSourcesView() }
                    NavigationLink("Limitations and disclaimers") { DisclaimerView() }
                }
                .disabled(settingsUnavailable)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingCalibration) { BPCalibrationView() }
            .sheet(item: $retentionProposal) { proposal in
                RetentionConfirmationView(proposal: proposal) {
                    applyRetention(proposal)
                }
            }
            .confirmationDialog(resetProposal?.title ?? "Clear data?", isPresented: Binding(
                get: { resetProposal != nil },
                set: { if !$0 { resetProposal = nil } }
            ), titleVisibility: .visible) {
                if let proposal = resetProposal {
                    Button(proposal.actionTitle, role: .destructive) { performReset(proposal) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(resetProposal?.message ?? "")
            }
            .alert("Storage result", isPresented: Binding(
                get: { persistenceResult != nil },
                set: { if !$0 { persistenceResult = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(persistenceResult ?? "") }
            .onAppear { retentionSelection = settings.snapshot.retentionDays }
            .onChange(of: settings.snapshot.mirrorBluetoothToHealthKit) { _, enabled in
                guard enabled else { return }
                Task {
                    let outcome = await model.healthKit.requestWriteAuthorization()
                    switch outcome {
                    case .granted:
                        mirrorWriteAlert = .granted
                    case .denied:
                        // Leave the toggle off so write(_:) is not attempted without share auth.
                        settings.snapshot.mirrorBluetoothToHealthKit = false
                        mirrorWriteAlert = .denied(
                            model.healthKit.lastError
                                ?? "Health write access was not granted. Enable it in Settings \u{2192} Health \u{2192} Data Access & Devices."
                        )
                    case .unavailable:
                        settings.snapshot.mirrorBluetoothToHealthKit = false
                        mirrorWriteAlert = .unavailable
                    }
                }
            }
            .alert(
                mirrorWriteAlert?.title ?? "",
                isPresented: Binding(
                    get: { mirrorWriteAlert != nil },
                    set: { if !$0 { mirrorWriteAlert = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(mirrorWriteAlert?.message ?? "")
            }
        }
    }

    private var settingsUnavailable: Bool {
        model.settings.loadState == .failed
    }

    private func proposeRetention(_ days: Int) {
        guard days != model.settings.snapshot.retentionDays else { return }
        if days < model.settings.snapshot.retentionDays {
            retentionProposal = RetentionProposal(
                days: days,
                impact: model.store.retentionImpact(days: days)
            )
        } else {
            applyRetention(RetentionProposal(days: days, impact: model.store.retentionImpact(days: days)))
        }
    }

    private func applyRetention(_ proposal: RetentionProposal) {
        model.settings.snapshot.retentionDays = proposal.days
        retentionSelection = proposal.days
        model.applyRetentionSettings()
        model.store.prune()
        retentionProposal = nil
        Task {
            let storeSaved = await model.store.saveNow()
            let settingsSaved = await model.settings.saveNow()
            let saved = storeSaved && settingsSaved
            persistenceResult = saved
                ? "The retention change was saved."
                : "The retention change is in memory but could not be confirmed on disk. Retry before relying on it."
        }
    }

    private func performReset(_ proposal: ResetProposal) {
        resetProposal = nil
        Task {
            let saved = await model.resetLocalData(proposal.mode)
            persistenceResult = saved
                ? proposal.successMessage
                : "The clear operation could not be fully confirmed on disk. No Apple Health data was deleted."
        }
    }

    @ViewBuilder
    private var bloodPressureSection: some View {
        @Bindable var settings = model.settings

        Section {
            Toggle("Show blood pressure index", isOn: $settings.snapshot.bloodPressureIndexEnabled)

            if settings.snapshot.bloodPressureIndexEnabled {
                if let calibration = settings.profile.bpCalibration {
                    LabeledContent("Calibrated at") {
                        Text("\(Int(calibration.systolic))/\(Int(calibration.diastolic))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    // "120/80" is spoken as "120 slash 80" without this.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Calibrated at")
                    .accessibilityValue("\(Int(calibration.systolic)) over \(Int(calibration.diastolic)) millimetres of mercury")
                    LabeledContent(calibration.isExpired ? "Expired" : "Expires") {
                        Text(calibration.expiresAt, format: .dateTime.day().month().year())
                            .foregroundStyle(calibration.isExpired ? .red : .secondary)
                    }
                    // Red is the only visual marker that the anchor is stale; the label says it.
                    .accessibilityElement(children: .combine)
                    Button("Re-calibrate") { showingCalibration = true }
                        .accessibilityHint("Replaces the cuff reading the blood pressure index is anchored to")
                } else {
                    Button("Add cuff calibration") { showingCalibration = true }
                        .accessibilityHint("Anchors the blood pressure index to a reading from a validated cuff")
                }
            }
        } header: {
            Text("Blood pressure")
        } footer: {
            Text("No ring or watch can measure blood pressure optically. What HeartSync shows is a trend index: how far your heart rate and HRV have drifted from where they were when you took a real cuff reading. It is not a blood pressure measurement and must not be used for any medical decision. Real cuff readings from a Bluetooth or Health-connected monitor are shown separately, as measurements.")
        }
    }

    /// Retention footer, which has to be honest about the difference between how *long*
    /// history is kept and at what *fidelity*.
    ///
    /// The picker only chooses the first. `HealthStore` compacts anything older than
    /// `compactionAge` down to one median per device per `ComparisonEngine` window — the
    /// same windowed median the Compare tab and every export already consume — so a year of
    /// retention is a year of windowed medians, not a year of raw one-per-second samples.
    /// The comparison median and verdict survive. New aggregates preserve original count and
    /// standard deviation; legacy aggregates report those facts as unknown. Individual rows,
    /// the full distribution, and later correction do not survive.
    /// The age is read from the store rather than hard-coded so the two cannot drift apart.
    private var retentionFooter: String {
        let days = max(1, Int((model.store.compactionAge / 86_400).rounded()))
        return """
        All readings stay on this device. HeartSync has no account, no server, and sends \
        nothing anywhere except the requests it makes to Oura on your behalf.

        Readings older than \(days) days are permanently compacted: each device's samples \
        within a comparison window are replaced by that window's median. This preserves the \
        comparison value and verdict. New medians retain their original sample count and \
        standard deviation; older migrated medians show those facts as unknown. Individual \
        samples, the full distribution, and later corrections are lost. A longer retention \
        therefore keeps a longer history of fixed windowed medians, not every raw sample.
        """
    }

    private var profileSummary: String {
        let profile = model.settings.profile
        if let age = profile.age { return "\(age) years" }
        return "Not set"
    }

    private var toleranceSummary: String {
        let examples: [MetricKind] = [.heartRate, .spo2, .hrvRMSSD]
        let parts = examples.map { "\($0.shortTitle) \($0.format($0.agreement.warn))\($0.unit == "%" ? "%" : " \($0.unit)")" }
        return "Tolerances are per metric \u{2014} \(parts.joined(separator: ", ")). They reflect each metric's real-world measurement error, so a gap only gets flagged when it exceeds what both devices' own accuracy would explain."
    }
}

private struct RetentionProposal: Identifiable {
    var id: Int { days }
    var days: Int
    var impact: HealthStore.RetentionImpact
}

private enum ResetProposal: Identifiable {
    case clearForResync
    case forgetImportedHistory

    var id: String { actionTitle }
    var mode: AppModel.DataResetMode {
        switch self {
        case .clearForResync: .clearForResync
        case .forgetImportedHistory: .forgetImportedHistory
        }
    }
    var title: String {
        switch self {
        case .clearForResync: "Clear the resyncable cache?"
        case .forgetImportedHistory: "Forget imported history?"
        }
    }
    var actionTitle: String {
        switch self {
        case .clearForResync: "Clear cache"
        case .forgetImportedHistory: "Forget history"
        }
    }
    var message: String {
        switch self {
        case .clearForResync:
            "Clears local readings and the Oura dashboard, resets HealthKit anchors, and keeps connections. Apple Health and Oura can repopulate their data on the next sync."
        case .forgetImportedHistory:
            "Clears local readings, disconnects Oura, and keeps HealthKit anchors so older Health history does not immediately return. Future Bluetooth and Health samples can still appear. Apple Health itself is not deleted."
        }
    }
    var successMessage: String {
        switch self {
        case .clearForResync: "The local cache was cleared and saved. Connected sources may resync."
        case .forgetImportedHistory: "Imported history was forgotten and saved. Apple Health itself was not changed."
        }
    }
}

private struct RetentionConfirmationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let proposal: RetentionProposal
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("New cutoff") {
                        Text(proposal.impact.cutoff, format: .dateTime.year().month().day())
                    }
                    LabeledContent("Readings deleted") { Text("\(proposal.impact.readingsDeleted)") }
                    LabeledContent("Older rows eligible for compaction") {
                        Text("\(proposal.impact.readingsEligibleForCompaction)")
                    }
                } header: {
                    Text("Shorter retention")
                        .accessibilityIdentifier("retention.confirmation")
                } footer: {
                    Text("Deletion and compaction are irreversible. Compacted medians retain known original counts and spread, but individual rows and later corrections are lost.")
                }
                Section {
                    ShareLink(item: model.store.exportCSV()) {
                        Label("Export readings before changing", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("retention.export")
                }
            }
            .navigationTitle("Confirm retention")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .destructive) { apply() }
                        .accessibilityIdentifier("retention.apply")
                }
            }
        }
    }
}

/// Alert payload after the mirroring toggle asks for HealthKit write access.
private enum MirrorWriteAlert: Identifiable {
    case granted
    case denied(String)
    case unavailable

    var id: String {
        switch self {
        case .granted: return "granted"
        case .denied(let message): return "denied:\(message)"
        case .unavailable: return "unavailable"
        }
    }

    var title: String {
        switch self {
        case .granted:
            "Health writing enabled"
        case .denied:
            "Health writing not enabled"
        case .unavailable:
            "Health unavailable"
        }
    }

    var message: String {
        switch self {
        case .granted:
            "Bluetooth readings can be written to Apple Health."
        case .denied(let detail):
            detail
        case .unavailable:
            "Health data is not available on this device."
        }
    }
}

// MARK: - Profile

private struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var birthDate = Date.now
    @State private var hasBirthDate = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                Toggle("Set date of birth", isOn: $hasBirthDate)
                if hasBirthDate {
                    DatePicker("Date of birth", selection: $birthDate, in: ...Date.now, displayedComponents: .date)
                }
            } footer: {
                if let maxHR = settings.profile.estimatedMaxHeartRate {
                    Text("Age-predicted maximum heart rate: \(Int(maxHR.rounded())) bpm, using 208 \u{2212} 0.7 \u{00D7} age (Tanaka et al.).")
                }
            }

            Section {
                Button("Import from Apple Health") { model.importProfileFromHealth() }
                    .disabled(model.healthKit.availability != .authorized)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let existing = settings.profile.birthDate {
                birthDate = existing
                hasBirthDate = true
            }
        }
        .onChange(of: hasBirthDate) { _, on in
            settings.snapshot.profile.birthDate = on ? birthDate : nil
        }
        .onChange(of: birthDate) { _, date in
            if hasBirthDate { settings.snapshot.profile.birthDate = date }
        }
    }
}

// MARK: - Blood pressure calibration

private struct BPCalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var systolic = 120.0
    @State private var diastolic = 80.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Take a reading with a validated blood pressure cuff, sitting still, and enter it here along with wearing your sensor. HeartSync records your heart rate and HRV at this moment as the reference point.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Cuff reading") {
                    Stepper(value: $systolic, in: 70...220, step: 1) {
                        LabeledContent("Systolic") {
                            Text("\(Int(systolic)) mmHg").monospacedDigit()
                        }
                    }
                    Stepper(value: $diastolic, in: 40...140, step: 1) {
                        LabeledContent("Diastolic") {
                            Text("\(Int(diastolic)) mmHg").monospacedDigit()
                        }
                    }
                }

                Section {
                    LabeledContent("Current heart rate") {
                        Text(currentHR.map { "\(Int($0)) bpm" } ?? "No reading")
                            .foregroundStyle(currentHR == nil ? .red : .secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current heart rate")
                    .accessibilityValue(currentHR.map { "\(Int($0)) beats per minute" } ?? "No reading")
                    LabeledContent("Current HRV (RMSSD)") {
                        Text(currentRMSSD.map { "\(Int($0)) ms" } ?? "Not available")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current HRV, RMSSD")
                    .accessibilityValue(currentRMSSD.map { "\(Int($0)) milliseconds" } ?? "Not available")
                } header: {
                    Text("Reference state")
                } footer: {
                    Text(currentHR == nil
                        ? "A live heart rate is required. Connect a sensor and wait for a reading before calibrating."
                        : "The index is expressed relative to these values. It expires after 30 days, because a month-old anchor is no longer informative.")
                }

                Section {
                    EstimateDisclaimer(text: Estimators.BloodPressureEstimate.disclaimer)
                }
            }
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(currentHR == nil || systolic <= diastolic)
                }
            }
        }
    }

    private var currentHR: Double? {
        let readings = model.store.readings(
            kind: .heartRate,
            in: DateInterval(start: .now.addingTimeInterval(-600), end: .now)
        )
        return ComparisonEngine.windows(from: readings, kind: .heartRate).last?.consensus
    }

    private var currentRMSSD: Double? {
        let readings = model.store.readings(
            kind: .hrvRMSSD,
            in: DateInterval(start: .now.addingTimeInterval(-3600), end: .now)
        )
        return ComparisonEngine.windows(from: readings, kind: .hrvRMSSD).last?.consensus
    }

    private func save() {
        guard let hr = currentHR else { return }
        model.settings.snapshot.profile.bpCalibration = UserProfile.BPCalibration(
            systolic: systolic,
            diastolic: diastolic,
            referenceRestingHR: hr,
            referenceRMSSD: currentRMSSD,
            takenAt: .now
        )
        model.ensureEstimateSourceExists()
        model.recomputeDerivedMetrics()
        dismiss()
    }
}
