import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("App settings persistence guard")
@MainActor
struct AppSettingsPersistenceTests {

    private func fixture() throws -> (folder: URL, archiveName: String, file: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        let name = "settings-tests-\(UUID().uuidString)"
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, "\(name)/settings.json", folder.appendingPathComponent("settings.json"))
    }

    @Test("Settings cannot be written before the archive has been conclusively read")
    func savingWaitsForLoad() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let settings = AppSettings(archiveName: fixture.archiveName)

        #expect(settings.loadState == .notLoaded)
        await settings.saveNow()
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        await settings.loadIfNeeded()
        #expect(settings.loadState == .loaded)
    }

    @Test("An unreadable settings archive is preserved and retried after access returns")
    func unreadableArchiveIsRetried() async throws {
        let fixture = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
            try? FileManager.default.removeItem(at: fixture.folder)
        }

        var archived = SettingsSnapshot()
        archived.retentionDays = 180
        let original = try JSONEncoder().encode(archived)
        try original.write(to: fixture.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.file.path)

        let settings = AppSettings(archiveName: fixture.archiveName)
        await settings.loadIfNeeded()
        #expect(settings.loadState == .failed)

        // A lifecycle save in this state must not replace the inaccessible file with the
        // in-memory defaults.
        await settings.saveNow()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
        #expect(try Data(contentsOf: fixture.file) == original)

        await settings.loadIfNeeded()
        #expect(settings.loadState == .loaded)
        #expect(settings.snapshot == archived)
    }
}
