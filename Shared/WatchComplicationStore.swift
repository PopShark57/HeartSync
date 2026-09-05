import Foundation

/// One replaceable, token-free display snapshot shared only by the watch app and its
/// WidgetKit extension. The extension is read-only; WatchConnectivity remains in the app.
struct WatchComplicationStore {
    static let appGroup = "group.com.heartsync.HeartSyncChecker.watch"
    static let metricWidgetKind = "HeartSyncMeasurement"
    private let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    #if os(watchOS)
    init() {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        directory = container?.appendingPathComponent("Complications", isDirectory: true)
    }
    #endif

    func load() throws -> WatchSnapshot? {
        guard let directory else { throw StoreError.unavailableContainer }
        let file = directory.appendingPathComponent("complication-snapshot-v1.json")
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= WatchSnapshot.maximumBytes else { throw WatchSnapshot.PayloadError.tooLarge }
            return try WatchSnapshot.decode(Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// A valid reset/unavailable snapshot replaces previous values. Never turn an unreadable
    /// protected file into an empty cache, and never resurrect data with an older delivery.
    @discardableResult
    func save(_ snapshot: WatchSnapshot) throws -> Bool {
        let data = try snapshot.encoded()
        guard let directory else { throw StoreError.unavailableContainer }
        let previous: WatchSnapshot?
        do {
            previous = try load()
        } catch is DecodingError {
            previous = nil // This disposable cache can be rebuilt from a validated context.
        } catch is WatchSnapshot.PayloadError {
            previous = nil
        }
        if let previous {
            guard snapshot.generatedAt >= previous.generatedAt, snapshot != previous else { return false }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Establish backup exclusion before replacing data. A metadata failure must not
        // leave a committed snapshot whose later duplicate skips the timeline reload.
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let file = directory.appendingPathComponent("complication-snapshot-v1.json")
        #if os(watchOS) || os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return true
    }

    enum StoreError: Error { case unavailableContainer }
}
