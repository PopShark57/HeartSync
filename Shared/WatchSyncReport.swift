import Foundation

/// The wrist's "Sync all sources" request and the iPhone's reply.
///
/// The request is an immediate message that asks the iPhone to do what the Devices tab's
/// buttons do one by one: reconnect known Bluetooth devices, start Import stored on every
/// identified ring, re-read Apple Health, and sync Oura. The reply says what happened to
/// each, so the wrist never implies a transport synced when it did not. Readings still
/// reach the watch only in the next snapshot; this carries no health values.
struct WatchSyncReport: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let requestKey = "heartsync.syncAll.v1"
    static let replyKey = "heartsync.syncReport.v1"
    static let maximumBytes = 2_048
    /// The iPhone replies by this time even when a transport is still running, because
    /// WatchConnectivity does not promise to hold a reply open for long.
    static let replyDeadline: TimeInterval = 25
    /// The least time between two sync-all runs; a request inside it is answered at once.
    static let minimumInterval: TimeInterval = 60

    enum Status: String, Codable, Sendable {
        /// Every transport finished before the reply.
        case completed
        /// The reply deadline passed; the rest continues on iPhone.
        case stillRunning
        /// A sync-all ran less than `minimumInterval` ago; nothing new was started.
        case tooSoon
        /// Health history is not loaded on iPhone (for example, before first unlock).
        case unavailable
    }

    enum Outcome: String, Codable, Sendable {
        case synced
        /// Some collections or types could not be read; what was read is kept.
        case partial
        case failed
        /// Oura asked HeartSync to wait; what was fetched before that is kept.
        case rateLimited
        /// Not connected on iPhone, so nothing was asked.
        case notConnected
        /// Not finished by the reply deadline.
        case running
    }

    var version = currentVersion
    var status: Status
    var finishedAt: Date
    var health: Outcome = .notConnected
    var oura: Outcome = .notConnected
    /// Enabled Bluetooth devices asked to reconnect. A healthy link is left as it is.
    var bluetoothDevices = 0
    /// False when the iPhone's Bluetooth is off, so no device could be asked.
    var bluetoothPoweredOn = true
    /// Rings that started importing their stored readings. Their values arrive later.
    var ringImports = 0

    static func unavailable(at date: Date = .now) -> Self {
        Self(status: .unavailable, finishedAt: date)
    }

    static func tooSoon(at date: Date = .now) -> Self {
        Self(status: .tooSoon, finishedAt: date)
    }

    func encoded() throws -> Data {
        guard isValid else { throw WatchSnapshot.PayloadError.invalid }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw WatchSnapshot.PayloadError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WatchSnapshot.PayloadError.tooLarge }
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.version == currentVersion else { throw WatchSnapshot.PayloadError.unsupportedVersion }
        guard report.isValid else { throw WatchSnapshot.PayloadError.invalid }
        return report
    }

    private var isValid: Bool {
        finishedAt.timeIntervalSince1970.isFinite
            && (0...64).contains(bluetoothDevices)
            && (0...bluetoothDevices).contains(ringImports)
    }

    // MARK: Presentation

    /// One line per transport, in the order the Devices tab lists them.
    var lines: [String] {
        switch status {
        case .unavailable:
            return [String(
                localized: "watch.sync.unavailable",
                defaultValue: "iPhone data is unavailable. Unlock your iPhone and open HeartSync.",
                comment: "Wrist sync-all reply: the iPhone could not read its health history"
            )]
        case .tooSoon:
            return [String(
                localized: "watch.sync.tooSoon",
                defaultValue: "Synced less than a minute ago. Try again shortly.",
                comment: "Wrist sync-all reply: a sync ran moments ago, so none was started"
            )]
        case .completed, .stillRunning:
            var lines = [
                String(
                    localized: "watch.sync.health",
                    defaultValue: "Health: \(Self.text(health))",
                    comment: "Wrist sync-all result for Apple Health. The argument is an outcome such as 'synced'."
                ),
                String(
                    localized: "watch.sync.oura",
                    defaultValue: "Oura: \(Self.text(oura))",
                    comment: "Wrist sync-all result for Oura. The argument is an outcome such as 'synced'."
                ),
                bluetoothLine,
            ]
            if ringImports > 0 {
                lines.append(String(
                    localized: "watch.sync.rings",
                    defaultValue: "Importing stored readings from \(ringImports) rings. They arrive with a later update.",
                    comment: "Wrist sync-all result. The argument is how many rings started importing stored readings."
                ))
            }
            if status == .stillRunning {
                lines.append(String(
                    localized: "watch.sync.stillRunning",
                    defaultValue: "Still syncing on iPhone. New readings follow in the next update.",
                    comment: "Wrist sync-all reply sent before every transport finished"
                ))
            }
            return lines
        }
    }

    private var bluetoothLine: String {
        if bluetoothDevices == 0 {
            return String(
                localized: "watch.sync.bluetooth.none",
                defaultValue: "Bluetooth: no devices",
                comment: "Wrist sync-all result: no Bluetooth devices are set up on iPhone"
            )
        }
        if !bluetoothPoweredOn {
            return String(
                localized: "watch.sync.bluetooth.off",
                defaultValue: "Bluetooth: off on iPhone",
                comment: "Wrist sync-all result: the iPhone's Bluetooth is turned off"
            )
        }
        return String(
            localized: "watch.sync.bluetooth.devices",
            defaultValue: "Bluetooth: \(bluetoothDevices) devices, reconnecting any that dropped",
            comment: "Wrist sync-all result. The argument is how many Bluetooth devices were checked; connected ones are left as they are."
        )
    }

    static func text(_ outcome: Outcome) -> String {
        switch outcome {
        case .synced:
            String(localized: "watch.sync.outcome.synced", defaultValue: "synced", comment: "Wrist sync-all outcome")
        case .partial:
            String(localized: "watch.sync.outcome.partial", defaultValue: "partly synced", comment: "Wrist sync-all outcome: some data could not be read")
        case .failed:
            String(localized: "watch.sync.outcome.failed", defaultValue: "failed, see iPhone", comment: "Wrist sync-all outcome")
        case .rateLimited:
            String(localized: "watch.sync.outcome.rateLimited", defaultValue: "paused by a rate limit", comment: "Wrist sync-all outcome: Oura asked HeartSync to wait")
        case .notConnected:
            String(localized: "watch.sync.outcome.notConnected", defaultValue: "not connected", comment: "Wrist sync-all outcome: the source is not set up on iPhone")
        case .running:
            String(localized: "watch.sync.outcome.running", defaultValue: "still syncing", comment: "Wrist sync-all outcome: not finished when iPhone replied")
        }
    }
}
