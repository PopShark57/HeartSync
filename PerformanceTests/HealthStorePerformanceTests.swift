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

    /// The flows a user actually drives, at the scale the workload above produces.
    ///
    /// The single-source insert-and-query test does not exercise what the comparison
    /// screens and the export cost: two sources, a month-range pairwise pass, a range
    /// change while ingestion is still running, and the retention/export flow. Each stage
    /// prints its duration so a release run has numbers to compare against a budget rather
    /// than an impression of smoothness.
    ///
    /// Budgets are deliberately not asserted here. They belong to a specific device and
    /// have to be established by measuring one first; failing an unmeasured threshold on
    /// CI-less hardware would only teach people to ignore this test.
    @Test("Two-source comparison, range changes during ingest, and export stay workable")
    func comparisonAndExportWorkload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-device-comparison-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: directory.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: directory)
        )
        await store.loadIfNeeded()
        #expect(store.loadState == .loaded)

        // A chest strap at 1 Hz and a ring reporting every five minutes: the realistic
        // asymmetric case, not two identical streams.
        let strapID = "performance.strap"
        let ringID = "performance.ring"
        store.upsert(DataSource(id: strapID, displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: ringID, displayName: "Ring", transport: .oura))

        let days = 30
        let end = Date.now.addingTimeInterval(-1)
        let start = end.addingTimeInterval(-TimeInterval(days * 86_400))
        let clock = ContinuousClock()
        let ingestStart = clock.now
        var rangeChangeDurations: [Duration] = []

        // One hour of strap data per batch, so a range change can be interleaved between
        // batches the way a user switching tabs mid-import would land.
        for hour in 0..<(days * 24) {
            let base = start.addingTimeInterval(TimeInterval(hour) * 3_600)
            var batch = (0..<3_600).map { second in
                Reading(
                    id: UUID(stableFrom: "perf.strap.\(hour).\(second)"),
                    sourceID: strapID,
                    kind: .heartRate,
                    value: 60 + Double((hour + second) % 40),
                    start: base.addingTimeInterval(TimeInterval(second)),
                    provenance: .measured
                )
            }
            for slot in 0..<12 {
                batch.append(Reading(
                    id: UUID(stableFrom: "perf.ring.\(hour).\(slot)"),
                    sourceID: ringID,
                    kind: .heartRate,
                    value: 62 + Double((hour + slot) % 36),
                    start: base.addingTimeInterval(TimeInterval(slot) * 300),
                    provenance: .measured
                ))
            }
            _ = store.append(contentsOf: batch)

            // A range change during ingestion, which is when the UI is least responsive.
            if hour % 120 == 0 {
                let changeStart = clock.now
                _ = store.readings(
                    kind: .heartRate,
                    in: DateInterval(start: end.addingTimeInterval(-3_600), end: end)
                )
                rangeChangeDurations.append(changeStart.duration(to: clock.now))
            }
            await Task.yield()
        }
        let ingestDuration = ingestStart.duration(to: clock.now)

        // The month-range pairwise pass the Compare screen performs.
        let analysisStart = clock.now
        let monthInterval = DateInterval(start: start, end: end)
        let readings = try store.readingsOutcome(in: monthInterval).get()
        let analyses = ComparisonEngine.allPairwiseAnalyses(from: readings, range: monthInterval)
        let analysisDuration = analysisStart.duration(to: clock.now)
        #expect(analyses.contains { $0.kind == .heartRate })

        // The retention/export flow, paged into a file rather than one in-memory string.
        let exportURL = directory.appendingPathComponent("export.csv")
        let exportStart = clock.now
        let rows = try store.writeExportCSV(to: exportURL)
        let exportDuration = exportStart.duration(to: clock.now)
        #expect(rows == store.readingCount)

        let attributes = try FileManager.default.attributesOfItem(atPath: exportURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0

        print("""
            Two-source month workload
              rows: \(store.readingCount)
              ingest: \(ingestDuration)
              month analysis: \(analysisDuration) over \(readings.count) readings, \(analyses.count) pairs
              export: \(exportDuration) for \(rows) rows, \(bytes) bytes
              range changes during ingest: \(rangeChangeDurations.map(\.description).joined(separator: ", "))
            """)
    }

    // MARK: - Live screens during ingest

    /// Longest acceptable single Now reload. The screen reloads at most once a second
    /// during live ingest, so this is the per-second main-thread cost of keeping Now current.
    static let nowReloadBudget: Duration = .milliseconds(50)

    /// Largest acceptable share of main-thread time spent reloading Now and an open 30-day
    /// detail screen while a strap streams at 1 Hz. The rest is left for scrolling,
    /// animation, and the ingest itself.
    ///
    /// Both budgets are initial values chosen before any device run, set so a regression to
    /// per-reading reloads fails them clearly. Confirm or tune them on the first
    /// representative-device measurement and record the result in `RELEASE_CHECKLIST.md`.
    static let mainThreadShareBudget = 0.25

    /// Now and a 30-day metric detail left open while a strap streams at 1 Hz on top of two
    /// weeks of history (improvement 29).
    ///
    /// Replays the screens' own reload rule, `LiveReloadPolicy`, against a simulated clock:
    /// each simulated second appends one strap reading, and a screen rebuilds its snapshot
    /// only when the policy would let it. Snapshot construction is exactly what the screens
    /// run on the main actor, so the summed durations are the main-thread cost of staying
    /// current. The previous behaviour — a reload after every reading, and a two-day read
    /// for every metric on Now — is what these budgets exist to keep out.
    @Test("Now and a 30-day detail stay within a main-thread budget during 1 Hz ingest")
    func liveScreensDuringIngest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-device-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: directory.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: directory)
        )
        await store.loadIfNeeded()
        #expect(store.loadState == .loaded)

        let strapID = "performance.live-strap"
        let ringID = "performance.live-ring"
        store.upsert(DataSource(id: strapID, displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: ringID, displayName: "Ring", transport: .oura))

        // Two weeks of history, ending where the simulated live minute begins.
        let liveSeconds = 120
        let historyEnd = Date.now.addingTimeInterval(-TimeInterval(liveSeconds) - 1)
        let historyStart = historyEnd.addingTimeInterval(-14 * 86_400)
        for hour in 0..<(14 * 24) {
            let base = historyStart.addingTimeInterval(TimeInterval(hour) * 3_600)
            var batch = (0..<3_600).map { second in
                Reading(
                    id: UUID(stableFrom: "perf.live.strap.\(hour).\(second)"),
                    sourceID: strapID,
                    kind: .heartRate,
                    value: 60 + Double((hour + second) % 40),
                    start: base.addingTimeInterval(TimeInterval(second))
                )
            }
            for slot in 0..<12 {
                batch.append(Reading(
                    id: UUID(stableFrom: "perf.live.ring.\(hour).\(slot)"),
                    sourceID: ringID,
                    kind: .heartRate,
                    value: 62 + Double((hour + slot) % 36),
                    start: base.addingTimeInterval(TimeInterval(slot) * 300)
                ))
            }
            _ = store.append(contentsOf: batch)
            await Task.yield()
        }

        let clock = ContinuousClock()
        let detailPeriod = ComparisonPeriod.rolling(.month)
        var nowDurations: [Duration] = []
        var detailDurations: [Duration] = []
        var lastNowLoad: Date?
        var lastDetailLoad: Date?

        for second in 0..<liveSeconds {
            let stamp = historyEnd.addingTimeInterval(TimeInterval(second + 1))
            _ = store.append(Reading(
                id: UUID(stableFrom: "perf.live.stream.\(second)"),
                sourceID: strapID,
                kind: .heartRate,
                value: 70 + Double(second % 9),
                start: stamp
            ))

            if LiveReloadPolicy.delay(
                dataOnly: true,
                elapsed: lastNowLoad.map { stamp.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.liveScreenInterval
            ) <= LiveReloadPolicy.debounce {
                let started = clock.now
                _ = DashboardSnapshot(store: store, now: stamp)
                nowDurations.append(started.duration(to: clock.now))
                lastNowLoad = stamp
            }

            if LiveReloadPolicy.delay(
                dataOnly: true,
                elapsed: lastDetailLoad.map { stamp.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.minimumInterval(for: detailPeriod)
            ) <= LiveReloadPolicy.debounce {
                let started = clock.now
                _ = MetricDetailSnapshot(
                    store: store,
                    kind: .heartRate,
                    period: detailPeriod,
                    includeEstimates: true,
                    hrvQuality: [:]
                )
                detailDurations.append(started.duration(to: clock.now))
                lastDetailLoad = stamp
            }
            await Task.yield()
        }

        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        func mean(_ durations: [Duration]) -> Double {
            durations.isEmpty ? 0 : durations.map(seconds).reduce(0, +) / Double(durations.count)
        }
        let sortedNow = nowDurations.sorted()
        let nowP95 = sortedNow[min(sortedNow.count - 1, Int(Double(sortedNow.count) * 0.95))]
        let detailInterval = LiveReloadPolicy.minimumInterval(for: detailPeriod)
        // Steady state: each screen costs its mean reload time once per reload interval.
        // A month range reloads rarely, so a two-minute window may hold one detail reload;
        // measuring the share this way is still exact for the policy in force.
        let share = mean(nowDurations) / LiveReloadPolicy.liveScreenInterval + mean(detailDurations) / detailInterval

        print("""
            Live screens during 1 Hz ingest over two weeks of history
              rows: \(store.readingCount)
              Now reloads: \(nowDurations.count) in \(liveSeconds) s, p95 \(nowP95), max \(sortedNow.last ?? .zero)
              30-day detail reloads: \(detailDurations.count) (interval \(Int(detailInterval)) s), each \(detailDurations.map(\.description).joined(separator: ", "))
              steady-state main-thread share: \(String(format: "%.1f", share * 100))%
            """)

        // The rule itself: at most one Now reload a second and one detail reload per
        // interval, never one of each per reading.
        #expect(nowDurations.count <= liveSeconds)
        #expect(Double(detailDurations.count) <= Double(liveSeconds) / detailInterval + 1)
        #expect(nowP95 <= Self.nowReloadBudget)
        #expect(share <= Self.mainThreadShareBudget)
    }
}
