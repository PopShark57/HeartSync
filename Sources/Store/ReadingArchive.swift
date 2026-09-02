import Foundation
import OSLog

/// The on-disk wrapper every archive file is written inside.
///
/// Declared at file scope with split conditional conformances because `ReadingArchive.write`
/// constrains its payload to `Encodable` and `read` constrains it to `Decodable`; one
/// unconditional `Codable` envelope could not serve both.
private struct ArchiveEnvelope<Payload: Sendable>: Sendable {
    var schemaVersion: Int
    var payload: Payload
}

extension ArchiveEnvelope: Encodable where Payload: Encodable {}
extension ArchiveEnvelope: Decodable where Payload: Decodable {}

/// Just enough of the envelope to learn the version of a file we could not decode.
private struct ArchiveSchemaProbe: Decodable {
    var schemaVersion: Int
}

/// Off-main-actor file persistence for readings and configuration.
///
/// Kept as an actor so writes never block the UI while a live Bluetooth stream is filling
/// the store. Uses atomic writes so a crash mid-save cannot leave a truncated file that
/// fails to decode on next launch.
///
/// Every file is written inside a versioned envelope (`{"schemaVersion": N, "payload": …}`)
/// so a future model change has somewhere to branch. Reads accept both the envelope and the
/// bare payload written by earlier builds, and a legacy file is upgraded silently the next
/// time it is written. Nothing that fails to decode is ever deleted: it is moved aside as a
/// `.corrupt` backup, because a decode failure is far more likely to be an app bug than
/// genuinely worthless user health data.
///
/// Reads report a four-state `ReadOutcome` rather than an Optional. Collapsing "no file
/// yet" and "could not open the file" into `nil` is a data-loss bug, not a simplification:
/// the caller then starts empty and its next save overwrites a perfectly good archive. See
/// `ReadOutcome` and `HealthStore.loadState`.
actor ReadingArchive {
    static let shared = ReadingArchive()

    /// Envelope version this build writes and is able to read. Bump it only alongside a
    /// documented migration in `read`.
    static let schemaVersion = 1

    /// What one archive read established about a file.
    ///
    /// The distinction that matters is between `.missing` and `.unreadable`. `.missing`
    /// means the collection is genuinely empty and a caller may safely proceed with nothing
    /// and later write over the absent file. `.unreadable` means the user's data is still
    /// on disk and this process simply could not get at it — most plausibly because the
    /// device has not been unlocked since boot and the file's protection class has not
    /// released its key yet, which is reachable in this app because CoreBluetooth state
    /// restoration can relaunch it in the background before first unlock. Treating that as
    /// an empty store and saving would destroy the history.
    ///
    /// `.corrupt` is a third, separate thing: the file *was* opened and its bytes could not
    /// be decoded (or carry a schema newer than this build). Only that case moves the file
    /// aside to a `.corrupt` sibling; an unreadable file is never touched, because we have
    /// no evidence whatsoever about its contents.
    enum ReadOutcome<Value: Sendable>: Sendable {
        /// No such file. A first launch, or a collection never written.
        case missing
        /// The file exists and could not be opened. The data is intact and untouched;
        /// retry later. Carries the underlying error description for logging.
        case unreadable(String)
        /// The file was opened but could not be used, and has been preserved aside as a
        /// `.corrupt` sibling. Carries the reason.
        case corrupt(String)
        /// Decoded payload.
        case value(Value)

        /// The decoded payload, or `nil` for every outcome that did not produce one.
        var value: Value? {
            switch self {
            case .value(let payload): payload
            case .missing, .unreadable, .corrupt: nil
            }
        }

        /// True when this read established what the archive holds, so a caller may adopt
        /// the result and persist over it afterwards.
        ///
        /// `.corrupt` counts as conclusive on purpose: the original bytes have already been
        /// preserved beside the archive, the app deliberately starts fresh from there, and
        /// refusing to save afterwards would leave it unable to persist anything ever
        /// again. `.unreadable` is the only inconclusive outcome.
        var isConclusive: Bool {
            switch self {
            case .missing, .corrupt, .value: true
            case .unreadable: false
            }
        }
    }

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Archive")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Resolved once per process rather than on every file access.
    ///
    /// `ReadingArchive.shared` is a lazy global, so the directory is created the first time
    /// anything touches the archive and never again — the previous computed property issued
    /// a `createDirectory` syscall for every single read and write.
    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Writes `value` wrapped in the current schema envelope.
    ///
    /// **File protection class.** Set explicitly rather than left to the platform default,
    /// because the choice is load-bearing for a documented background path. The candidates,
    /// and what each would mean for this archive:
    ///
    /// - `.completeFileProtection`: the key is evicted whenever the device locks, so the
    ///   archive can be neither read nor written while locked. The app declares
    ///   `bluetooth-central` and keeps ingesting from a connected sensor with the screen
    ///   off, so this would drop every locked-session save on the floor.
    /// - `.completeFileProtectionUnlessOpen`: a file *already open* survives a lock, but a
    ///   closed one cannot be opened. This archive is never held open — every save is a
    ///   whole-file atomic write and every load is a fresh open — so the exemption buys
    ///   nothing, while the restriction is real: after a reboot, CoreBluetooth state
    ///   restoration (identifier `com.heartsync.central`) can relaunch this app in the
    ///   background *before the user has unlocked the device even once*, and under this
    ///   class the existing `readings.json` could not be opened at all. Rejected.
    /// - `.completeFileProtectionUntilFirstUserAuthentication`: the key becomes available
    ///   at the first unlock after boot and stays available until the device powers off.
    ///   Chosen. It still encrypts the health record at rest while the device is off — the
    ///   threat that matters for a lost or stolen phone — and it is the strongest class
    ///   that cannot break the locked-but-already-unlocked-once background session, which
    ///   is the overwhelmingly common case for a sleep-tracking sensor.
    /// - `.noFileProtection`: never, for a health record.
    ///
    /// The residual gap is the boot-to-first-unlock window, where both the read and the
    /// write still fail. That window is survivable only because a failed read is now
    /// reported as `.unreadable` and `HealthStore` refuses to persist over it; do not
    /// reintroduce a caller that maps a failed read to "empty".
    @discardableResult
    func write<T: Encodable & Sendable>(_ value: T, to name: String) -> Bool {
        do {
            let envelope = ArchiveEnvelope(schemaVersion: Self.schemaVersion, payload: value)
            let data = try encoder.encode(envelope)
            try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            logger.error("Failed to write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Reads `name`, accepting the current envelope or a bare legacy payload, and reports
    /// which of the four outcomes occurred.
    ///
    /// Order matters. The envelope is tried first, then the bare payload, and only then is
    /// the file inspected for a schema version newer than this build understands. Trying
    /// the bare payload before the version check is what keeps a payload that carries its
    /// *own* `schemaVersion` field — `OuraSnapshot` does — from being mistaken for a future
    /// archive and moved aside.
    ///
    /// Anything that cannot be decoded at all, and anything stamped with a newer schema
    /// version, is preserved as a `.corrupt` backup rather than deleted or trapped on. A
    /// file that could not be *opened* is left exactly where it is: an unreadable file is
    /// not an undecodable one, and moving a locked-out archive aside would manufacture the
    /// very data loss the `.corrupt` backup exists to prevent.
    func readOutcome<T: Decodable & Sendable>(_ type: T.Type, from name: String) -> ReadOutcome<T> {
        let fileURL = url(name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // With file protection enabled this legitimately fails while the device has not
            // been unlocked since boot. Leave the archive alone and let a later attempt
            // succeed; the caller must not treat this as an empty collection.
            let reason = error.localizedDescription
            logger.error("Failed to open \(name, privacy: .public): \(reason, privacy: .public)")
            return .unreadable(reason)
        }

        if let envelope = try? decoder.decode(ArchiveEnvelope<T>.self, from: data),
           envelope.schemaVersion <= Self.schemaVersion {
            return .value(envelope.payload)
        }
        if let legacy = try? decoder.decode(type, from: data) {
            // Written by a build that predates the envelope. The next write upgrades it.
            return .value(legacy)
        }

        let reason: String
        if let probe = try? decoder.decode(ArchiveSchemaProbe.self, from: data),
           probe.schemaVersion > Self.schemaVersion {
            reason = "schema \(probe.schemaVersion) is newer than this build understands"
        } else {
            // A decode failure usually means a model change. Move the file aside rather
            // than deleting it, so the data can be recovered if the change was a mistake.
            reason = "contents could not be decoded"
        }
        logger.error("Archive \(name, privacy: .public) unusable (\(reason, privacy: .public)); preserving it aside")
        preserveAside(fileURL)
        return .corrupt(reason)
    }

    /// Optional-shaped convenience for callers that genuinely cannot distinguish the
    /// outcomes — a cache that is rebuilt from the network either way.
    ///
    /// Anything that owns user history must use `readOutcome` instead: `nil` here means
    /// "no usable value", which deliberately includes "the file is fine and we could not
    /// open it".
    func read<T: Decodable & Sendable>(_ type: T.Type, from name: String) -> T? {
        readOutcome(type, from: name).value
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// Moves an unusable archive to a sibling `.corrupt` file. Never deletes user data.
    private func preserveAside(_ fileURL: URL) {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    enum File {
        static let readings = "readings.json"
        static let sources = "sources.json"
        static let settings = "settings.json"
        static let ouraDashboard = "oura-dashboard-v1.json"
    }
}
