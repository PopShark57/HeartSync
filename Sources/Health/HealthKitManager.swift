@preconcurrency import HealthKit
import Foundation
import Observation
import OSLog

/// Reads Apple Health, which is the only supported route to Apple Watch data.
///
/// There is no Bluetooth path to an Apple Watch: it is not a peripheral a third-party app
/// can connect to, and its sensor data is only exposed through HealthKit. That also means
/// anything else writing to Health \u{2014} the Oura app, a Whoop, a blood-pressure cuff \u{2014}
/// shows up here as its own source, which HeartSync keeps separate rather than merging.
@MainActor
@Observable
final class HealthKitManager {

    // Internal so HealthKitManager+Session (separate file) can log restore/write-auth paths.
    let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "HealthKit")

    enum Availability: Equatable {
        case unavailable
        case notDetermined
        case authorized
        case denied

        /// Apple Health connection status.
        ///
        /// `.authorized` deliberately says only that the sheet was completed: HealthKit
        /// never reports which read permissions were actually granted, and the wording
        /// must not be translated into a claim that every metric is readable.
        var title: String {
            switch self {
            case .unavailable:
                String(localized: "healthKit.availability.unavailable", defaultValue: "Health data is not available on this device", comment: "Apple Health status: HealthKit is unsupported on this hardware")
            case .notDetermined:
                String(localized: "healthKit.availability.notDetermined", defaultValue: "Not connected", comment: "Apple Health status: the user has not been asked for access yet")
            case .authorized:
                String(localized: "healthKit.availability.authorized", defaultValue: "Connected", comment: "Apple Health status: the authorization sheet was completed. This does not promise that any specific read permission was granted, so avoid wording that implies full access.")
            case .denied:
                String(localized: "healthKit.availability.denied", defaultValue: "Permission denied", comment: "Apple Health status: the user declined access")
            }
        }
    }

    // internal(set): Session extension restores/writes these across files.
    internal(set) var availability: Availability = .notDetermined
    private(set) var lastSyncedAt: Date?
    internal(set) var lastError: String?
    private(set) var isSyncing = false

    // Internal so HealthKitManager+Session can query authorization status.
    let healthStore = HKHealthStore()
    private var activeQueries: [HKQuery] = []
    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading]) -> Void)?
    private var onDeletedSampleIDs: (@MainActor ([UUID]) -> Void)?
