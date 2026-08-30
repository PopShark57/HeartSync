import Foundation
import OSLog

/// Off-main-actor file persistence for readings and configuration.
///
/// Kept as an actor so writes never block the UI while a live Bluetooth stream is filling
/// the store. Uses atomic writes so a crash mid-save cannot leave a truncated file that
/// fails to decode on next launch.
actor ReadingArchive {
    static let shared = ReadingArchive()

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

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func write<T: Encodable & Sendable>(_ value: T, to name: String) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url(name), options: .atomic)
        } catch {
            logger.error("Failed to write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func read<T: Decodable & Sendable>(_ type: T.Type, from name: String) -> T? {
        let fileURL = url(name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(type, from: data)
        } catch {
            // A decode failure usually means a model change. Move the file aside rather
            // than deleting it, so the data can be recovered if the change was a mistake.
            logger.error("Failed to read \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return nil
        }
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    enum File {
        static let readings = "readings.json"
        static let sources = "sources.json"
        static let settings = "settings.json"
        static let ouraDashboard = "oura-dashboard-v1.json"
    }
}
