import Foundation
import Observation

/// User-configurable behaviour. Persisted alongside the readings.
struct SettingsSnapshot: Codable, Hashable, Sendable {
    var profile = UserProfile()
    var retentionDays: Int = 30
    /// Write readings collected over Bluetooth back into Apple Health, so other apps can
    /// use them. Off by default \u{2014} writing into a user's health record is not something to
    /// opt them into silently.
    var mirrorBluetoothToHealthKit = false
    /// Show the blood-pressure trend index at all. Off until the user has read the
    /// explanation and entered a cuff calibration.
    var bloodPressureIndexEnabled = false
    /// Compute a VO\u{2082} max estimate from resting HR when no device measures it.
    var vo2MaxEstimateEnabled = true
    /// Only surface discrepancies at this severity or above.
    var discrepancyThreshold: DiscrepancySeverity = .notable
    /// Automatically pull from Oura when the app becomes active.
    var autoSyncOura = true
    /// Seconds between Oura pulls, floor-limited to respect the API's rate limits.
    var ouraSyncInterval: TimeInterval = 900
}

@MainActor
@Observable
final class AppSettings {
    var snapshot: SettingsSnapshot {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?
    private var isLoaded = false

    init(snapshot: SettingsSnapshot = SettingsSnapshot()) {
        self.snapshot = snapshot
    }

    var profile: UserProfile {
        get { snapshot.profile }
        set { snapshot.profile = newValue }
    }

    /// True when the blood-pressure index has everything it needs to produce a value.
    var canEstimateBloodPressure: Bool {
        guard snapshot.bloodPressureIndexEnabled,
              let calibration = snapshot.profile.bpCalibration
        else { return false }
        return !calibration.isExpired
    }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true
        if let loaded = await ReadingArchive.shared.read(SettingsSnapshot.self, from: ReadingArchive.File.settings) {
            snapshot = loaded
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let value = snapshot
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await ReadingArchive.shared.write(value, to: ReadingArchive.File.settings)
        }
    }

    func saveNow() async {
        await ReadingArchive.shared.write(snapshot, to: ReadingArchive.File.settings)
    }
}
