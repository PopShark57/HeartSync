import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCalibration = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        @Bindable var settings = model.settings

        NavigationStack {
            Form {
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

                Section {
                    Toggle("Estimate VO\u{2082} max", isOn: $settings.snapshot.vo2MaxEstimateEnabled)
                } header: {
                    Text("VO\u{2082} max")
                } footer: {
                    Text("For devices that report resting heart rate but not VO\u{2082} max, HeartSync estimates it as 15.3 \u{00D7} (max HR \u{00F7} resting HR), the Uth\u{2013}S\u{00F8}rensen formula. Its error is roughly 10\u{2013}15%, far wider than the difference between two real measurements, so estimates are marked as such and left out of disagreement analysis.")
                }

                bloodPressureSection

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

                Section {
                    Toggle("Auto-sync Oura", isOn: $settings.snapshot.autoSyncOura)
                    Toggle("Write Bluetooth data to Health", isOn: $settings.snapshot.mirrorBluetoothToHealthKit)
                } header: {
                    Text("Syncing")
                } footer: {
                    Text("Writing to Health shares readings from your Bluetooth sensors with your other apps. Only directly measured values are written \u{2014} nothing HeartSync estimated ever enters your health record.")
                }

                Section {
                    Picker("Keep readings for", selection: $settings.snapshot.retentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    LabeledContent("Stored readings") {
                        Text("\(model.store.readings.count)").foregroundStyle(.secondary)
                    }
                    Button("Delete all readings", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("All readings stay on this device. HeartSync has no account, no server, and sends nothing anywhere except the requests it makes to Oura on your behalf.")
                }

                Section {
                    NavigationLink("How each metric is obtained") { MetricSourcesView() }
                    NavigationLink("Limitations and disclaimers") { DisclaimerView() }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingCalibration) { BPCalibrationView() }
            .confirmationDialog(
                "Delete all readings?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { model.store.deleteAllReadings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your configured devices are kept. Readings already written to Apple Health are not affected.")
            }
            .onChange(of: settings.snapshot.retentionDays) { _, days in
                model.store.retention = TimeInterval(days) * 86_400
                model.store.prune()
            }
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
                    LabeledContent(calibration.isExpired ? "Expired" : "Expires") {
                        Text(calibration.expiresAt, format: .dateTime.day().month().year())
                            .foregroundStyle(calibration.isExpired ? .red : .secondary)
                    }
                    Button("Re-calibrate") { showingCalibration = true }
                } else {
                    Button("Add cuff calibration") { showingCalibration = true }
                }
            }
        } header: {
            Text("Blood pressure")
        } footer: {
            Text("No ring or watch can measure blood pressure optically. What HeartSync shows is a trend index: how far your heart rate and HRV have drifted from where they were when you took a real cuff reading. It is not a blood pressure measurement and must not be used for any medical decision. Real cuff readings from a Bluetooth or Health-connected monitor are shown separately, as measurements.")
        }
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
                Picker("Biological sex", selection: $settings.snapshot.profile.sex) {
                    ForEach(UserProfile.BiologicalSex.allCases) { Text($0.title).tag($0) }
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
                    LabeledContent("Current HRV (RMSSD)") {
                        Text(currentRMSSD.map { "\(Int($0)) ms" } ?? "Not available")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
