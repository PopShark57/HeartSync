import Foundation
import Observation
import OSLog

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
    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Settings")

    /// Genuine user edits schedule a coalesced save. Hydration from disk does not — see
    /// `hydrate(_:)`.
    var snapshot: SettingsSnapshot {
        didSet {
            guard !isHydrating else { return }
            scheduleSave()
        }
    }

    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private let persistenceEnabled: Bool
    private let archiveName: String
    private var hasLoggedSaveRefusal = false

    enum LoadState: Sendable, Equatable {
        case notLoaded
        case loaded
        case failed
    }

    private(set) var loadState: LoadState
    /// True only while `loadIfNeeded` is assigning the archived snapshot, so `didSet` can
    /// tell "the user changed something" from "we just read this off disk".
    private var isHydrating = false

    init(
        snapshot: SettingsSnapshot = SettingsSnapshot(),
        persistenceEnabled: Bool = true,
        archiveName: String = ReadingArchive.File.settings
    ) {
        self.snapshot = snapshot
        self.persistenceEnabled = persistenceEnabled
        self.archiveName = archiveName
        self.loadState = persistenceEnabled ? .notLoaded : .loaded
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
        guard persistenceEnabled else { return }
        guard loadState != .loaded else { return }

        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        let outcome = await ReadingArchive.shared.readOutcome(SettingsSnapshot.self, from: archiveName)
        guard outcome.isConclusive else {
            loadState = .failed
            logger.error("Settings archive unreadable; refusing to persist until a load succeeds")
            return
        }
        if let loaded = outcome.value { hydrate(loaded) }
        loadState = .loaded
        hasLoggedSaveRefusal = false
    }

    /// Installs a snapshot read back from the archive without scheduling a save of it.
    ///
    /// Assigning through `snapshot` directly would fire `didSet` and rewrite `settings.json`
    /// one second into every launch with byte-identical content, dirtying the file for no
    /// reason. Observation still sees the mutation, so views update normally.
    private func hydrate(_ loaded: SettingsSnapshot) {
        isHydrating = true
        snapshot = loaded
        isHydrating = false
    }

    private func scheduleSave() {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }
    }

    func saveNow() async {
        guard persistenceEnabled else { return }
        guard loadState == .loaded else {
            if !hasLoggedSaveRefusal {
                hasLoggedSaveRefusal = true
                logger.error("Refusing to save: settings archive load has not completed")
            }
            return
        }
        await ReadingArchive.shared.write(snapshot, to: archiveName)
    }
}
