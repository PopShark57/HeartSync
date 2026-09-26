import SwiftUI
import UIKit

/// A prepared export file waiting for the share sheet, plus the temporary directory that
/// holds it so the directory can be removed once the sheet is dismissed.
struct ReadingsExportPayload: Identifiable {
    let id = UUID()
    var url: URL
    var directory: URL

    /// Writes the CSV for one source (or the whole history when `sourceID` is nil) into a
    /// fresh temporary directory. Throws, and leaves nothing behind, on failure; returns nil
    /// when there are no rows, because an empty file must not look like an exported history.
    @MainActor
    static func prepare(store: HealthStore, sourceID: String?, filename: String) throws -> ReadingsExportPayload? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(filename)
        do {
            let rows = try store.writeExportCSV(to: url, sourceID: sourceID)
            guard rows > 0 else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return ReadingsExportPayload(url: url, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// `UIActivityViewController` for an exported readings file. UIKit only because SwiftUI
/// has no share sheet that accepts a file produced after the user asks for it.
struct ReadingsShareSheet: UIViewControllerRepresentable {
    var items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
