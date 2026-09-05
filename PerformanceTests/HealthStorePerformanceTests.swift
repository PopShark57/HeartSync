import Foundation
import Testing
@testable import HeartSyncChecker

/// Device-only release gate for the largest raw history HeartSync permits before
/// compaction becomes eligible. This target is intentionally separate from the PR scheme:
/// it writes 1,209,600 rows and should be run on a representative physical iPhone while
/// Instruments records responsiveness and memory.
@Suite("Indexed 14-day device workload", .serialized)
@MainActor
struct HealthStorePerformanceTests {
    @Test("One-Hz history remains complete and range-queryable")
    func fourteenDaysAtOneHertz() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-device-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: directory.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: directory)
        )
        await store.loadIfNeeded()
        #expect(store.loadState == .loaded)

        let sourceID = "performance.one-hz"
        store.upsert(DataSource(
            id: sourceID,
            displayName: "One-hertz performance fixture",
            transport: .bluetooth
        ))

        let secondsPerDay = 86_400
        let total = 14 * secondsPerDay
        let batchSize = 5_000
        let end = Date.now.addingTimeInterval(-1)
        let start = end.addingTimeInterval(-TimeInterval(total - 1))
        let clock = ContinuousClock()
        let insertionStart = clock.now

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(total, batchStart + batchSize)
            let readings = (batchStart..<batchEnd).map { offset in
                let timestamp = start.addingTimeInterval(TimeInterval(offset))
                return Reading(
                    id: UUID(stableFrom: "performance.\(offset)"),
                    sourceID: sourceID,
                    kind: .heartRate,
                    value: 60 + Double(offset % 40),
                    start: timestamp,
                    provenance: .measured
                )
            }
            #expect(store.append(contentsOf: readings).count == readings.count)
            // Real import paths arrive in bounded batches. Yielding here lets the release
            // run verify that progress UI and cancellation remain responsive.
            await Task.yield()
        }

        let queryStart = clock.now
        let lastDay = store.readings(
            kind: .heartRate,
            in: DateInterval(start: end.addingTimeInterval(-86_399), end: end)
        )
        let queryDuration = queryStart.duration(to: clock.now)
        let insertionDuration = insertionStart.duration(to: queryStart)

        #expect(store.readingCount == total)
        #expect(lastDay.count == secondsPerDay)
        #expect(store.latest(kind: .heartRate, sourceID: sourceID)?.end == end)
        print("14-day insertion: \(insertionDuration); one-day indexed query: \(queryDuration)")
    }
}
