import Foundation
import Observation

/// Runs one readings export off the main actor and publishes its progress, so the screen that
/// started it can animate a progress bar and offer Cancel while the file is written.
///
/// The export used to run on the main actor, where the spinner beside the button could not
/// move until the whole history had been written. The writer now runs detached on a pooled
/// read connection (`ReadingsExportPayload.prepare`); this object polls its `ExportProgress`
/// a few times a second and reports the outcome on the main actor.
@MainActor
@Observable
final class ReadingsExportJob {
    private(set) var isRunning = false
    /// Data rows written so far.
    private(set) var written = 0
    /// Rows in the snapshot being exported; nil until counted.
    private(set) var total: Int?

    /// 0…1 once the total is known and non-zero.
    var fractionComplete: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(written) / Double(total))
    }

    @ObservationIgnored private var progress: ExportProgress?

    static let pollInterval: Duration = .milliseconds(150)

    /// Starts an export, cancelling any that is running. `completion` receives the payload,
    /// nil when there were no rows, or the failure. A cancelled export reports nothing and
    /// leaves no file.
    func start(
        history: HealthHistory,
        sourceID: String?,
        filename: String,
        in base: URL = FileManager.default.temporaryDirectory,
        completion: @escaping @MainActor (Result<ReadingsExportPayload?, any Error>) -> Void
    ) {
        cancel()
        let progress = ExportProgress()
        self.progress = progress
        isRunning = true
        written = 0
        total = nil

        Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                Result {
                    try ReadingsExportPayload.prepare(
                        history: history,
                        sourceID: sourceID,
                        filename: filename,
                        progress: progress,
                        in: base
                    )
                }
            }
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.publish(progress)
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
            let result = await work.value
            poll.cancel()
            // Cancelled, superseded, or the screen is gone: nothing is reported, and a file
            // finished in the meantime is removed rather than left in `tmp`.
            guard let self, self.progress === progress, !progress.isCancelled else {
                if case .success(let payload?) = result {
                    try? FileManager.default.removeItem(at: payload.directory)
                }
                return
            }
            self.publish(progress)
            self.progress = nil
            self.isRunning = false
            if case .failure(let error) = result, error is CancellationError { return }
            completion(result)
        }
    }

    /// Stops the running export between pages; its partial file is deleted.
    func cancel() {
        progress?.cancel()
        progress = nil
        isRunning = false
    }

    private func publish(_ progress: ExportProgress) {
        guard self.progress === progress else { return }
        written = progress.written
        total = progress.total
    }
}
