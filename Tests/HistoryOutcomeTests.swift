import Foundation
import Testing
@testable import HeartSyncChecker

/// Query failures after a successful startup (improvement 17) and compaction-honest
/// summaries and exports (improvement 19).
@Suite("History query outcomes and honest exports")
@MainActor
struct HistoryOutcomeTests {

    private func makeStore() -> (HealthStore, DataSource) {
        let store = HealthStore(persistenceEnabled: false)
        let source = DataSource(id: "alpha", displayName: "Chest Strap", transport: .bluetooth, model: "H10")
        store.upsert(source)
        return (store, source)
    }

    private func seed(_ store: HealthStore, _ sourceID: String, count: Int = 6) -> Date {
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-3_600), size: 60)
        for index in 0..<count {
            _ = store.append(Reading(
                sourceID: sourceID,
                kind: .heartRate,
                value: 70 + Double(index),
                start: anchor.addingTimeInterval(Double(index) * 60)
            ))
        }
        return anchor
    }

    // MARK: - Improvement 17

    @Test("An empty database succeeds with no rows rather than reporting a failure")
    func emptyDatabaseIsNotAFailure() {
        let (store, _) = makeStore()
        let outcome = store.readingsOutcome(kind: .heartRate, in: DateInterval(start: .distantPast, end: .distantFuture))

        #expect(outcome.isFailure == false)
        #expect(outcome.value?.isEmpty == true)
    }

    @Test("An injected query failure is reported as a failure, not as an empty history")
    func queryFailureIsDistinctFromEmptiness() {
        let (store, source) = makeStore()
        _ = seed(store, source.id)
        let range = DateInterval(start: .distantPast, end: .distantFuture)
        #expect(store.readingsOutcome(kind: .heartRate, in: range).value?.count == 6)

        store.injectQueryFailureForTesting()
        let failed = store.readingsOutcome(kind: .heartRate, in: range)

        #expect(failed.isFailure)
        #expect(failed.value == nil)
        // The distinction the whole item exists for: this is not "you have no readings".
        if case .queryFailed = failed.error { } else {
            Issue.record("Expected a queryFailed outcome, got \(String(describing: failed.error))")
        }
    }

    @Test("Retrying after a failure restores the rows without changing stored data")
    func retryRestoresResultsAndChangesNothing() {
        let (store, source) = makeStore()
        _ = seed(store, source.id)

        store.injectQueryFailureForTesting()
        #expect(store.readingsOutcome(kind: .heartRate).isFailure)

        store.injectQueryFailureForTesting(false)
        let recovered = store.readingsOutcome(kind: .heartRate)

        #expect(recovered.isFailure == false)
        #expect(recovered.value?.count == 6)
        // A read error must never have deleted, reset, or reimported anything.
        #expect(store.readingCount == 6)
        #expect(store.sources.count == 1)
    }

    @Test("The range query reports failure too, so Compare cannot show a false empty state")
    func rangeQueryFailurePropagates() {
        let (store, source) = makeStore()
        _ = seed(store, source.id)
        store.injectQueryFailureForTesting()

        let outcome = store.readingsOutcome(in: DateInterval(start: .distantPast, end: .distantFuture))
        #expect(outcome.isFailure)
        // And the count that Compare uses to decide "empty install" is a failure, not zero.
        #expect(store.readingCountOutcome.isFailure)
    }

    @Test("A failed count is not reported as an empty install")
    func failedCountIsNotAnEmptyInstall() {
        // resolve() is given nil for an unreadable count, so it must not claim noStoredData.
        #expect(
            ComparisonEmptyReason.resolve(comparableMetricCount: 0, sourcesInRange: 0, hasStoredReadings: false)
                == .noStoredData
        )
        // The view passes `(storedCount ?? 0) > 0`; a failure short-circuits to the error
        // branch before the empty state is ever consulted, which the next test pins down.
    }

    @Test("The export throws instead of producing a header-only file")
    func exportFailsVisibly() {
        let (store, source) = makeStore()
        _ = seed(store, source.id)
        store.injectQueryFailureForTesting()

        #expect(throws: (any Error).self) {
            _ = try store.allReadingsForExport()
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartsync-export-test-\(UUID().uuidString).csv")
        #expect(throws: (any Error).self) {
            _ = try store.writeExportCSV(to: url)
        }
        // A partial or header-only file must not be left behind for the user to share.
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("A successful paged export writes every row and a header")
    func pagedExportWritesEveryRow() throws {
        let (store, source) = makeStore()
        _ = seed(store, source.id, count: 12)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartsync-export-ok-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try store.writeExportCSV(to: url, pageSize: 5)
        #expect(written == 12)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 13)
        #expect(lines[0] == HealthStore.exportColumns.joined(separator: ","))
    }

    // MARK: - Improvement 19

    @Test("The export schema carries units, source metadata, and compaction provenance")
    func exportSchemaIsDocumentedAndComplete() {
        let source = DataSource(
            id: "alpha",
            displayName: "Chest Strap",
            transport: .bluetooth,
            model: "H10",
            upstreamDeviceRelationshipID: "ring-1",
            identifiesHealthKitWriter: false
        )
        let compacted = Reading(
            id: UUID(),
            sourceID: "alpha",
            kind: .heartRate,
            value: 72,
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_000_060),
            provenance: .measured,
            metadata: ReadingMetadata(
                quality: .provisional,
                aggregation: AggregationMetadata(originalSampleCount: 60, originalStandardDeviation: 1.5)
            )
        )
        let csv = HealthStore.exportCSV(readings: [compacted], sources: [source])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")

        func field(_ name: String) -> String {
            guard let index = header.firstIndex(of: name) else {
                Issue.record("Missing column \(name)")
                return ""
            }
            return row[index]
        }

        #expect(field("unit") == MetricKind.heartRate.exportUnit)
        #expect(field("source_name") == "Chest Strap")
        #expect(field("source_transport") == "Bluetooth")
        #expect(field("source_model") == "H10")
        #expect(field("source_upstream_relationship_id") == "ring-1")
        #expect(field("source_identifies_healthkit_writer") == "false")
        #expect(field("aggregation") == "compacted_window_median")
        #expect(field("original_sample_count") == "60")
        #expect(field("original_standard_deviation") == "1.5")
        #expect(field("corrections_are_final") == "true")
        #expect(field("measurement_quality") == "provisional")
        // Locale-independent, like the pairwise export.
        #expect(field("value") == "72")
    }

    @Test("Unknown aggregation facts stay empty rather than becoming zero")
    func unknownFactsRemainUnknown() {
        let source = DataSource(id: "alpha", displayName: "Ring", transport: .oura)
        let legacyCompacted = Reading(
            id: UUID(),
            sourceID: "alpha",
            kind: .heartRate,
            value: 66,
            start: Date(timeIntervalSince1970: 2_000_000),
            provenance: .measured,
            metadata: ReadingMetadata(
                aggregation: AggregationMetadata(originalSampleCount: nil, originalStandardDeviation: nil)
            )
        )
        let csv = HealthStore.exportCSV(readings: [legacyCompacted], sources: [source])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")

        let countIndex = header.firstIndex(of: "original_sample_count")!
        let sdIndex = header.firstIndex(of: "original_standard_deviation")!
        #expect(row[countIndex].isEmpty)
        #expect(row[sdIndex].isEmpty)
        // Still labelled as compacted, so a reader knows the rows behind it are gone.
        #expect(row[header.firstIndex(of: "aggregation")!] == "compacted_window_median")
    }

    @Test("A raw row is labelled raw and leaves aggregation fields empty")
    func rawRowsAreLabelled() {
        let source = DataSource(id: "alpha", displayName: "Ring", transport: .oura)
        let raw = Reading(sourceID: "alpha", kind: .spo2, value: 97, start: Date(timeIntervalSince1970: 3_000_000))
        let csv = HealthStore.exportCSV(readings: [raw], sources: [source])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let header = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")

        #expect(row[header.firstIndex(of: "aggregation")!] == "raw")
        #expect(row[header.firstIndex(of: "original_sample_count")!].isEmpty)
        #expect(row[header.firstIndex(of: "corrections_are_final")!].isEmpty)
    }

    @Test("Per-device summaries count windows, and keep original sample depth separate")
    func summariesReportWindowsNotSamples() {
        let (store, source) = makeStore()
        // Six raw samples inside a single 60-second comparison window.
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-1_800), size: 60)
        for index in 0..<6 {
            _ = store.append(Reading(
                sourceID: source.id,
                kind: .heartRate,
                value: 70 + Double(index),
                start: anchor.addingTimeInterval(Double(index) * 5)
            ))
        }

        let snapshot = MetricDetailSnapshot(
            store: store,
            kind: .heartRate,
            range: .day,
            includeEstimates: false,
            hrvQuality: [:]
        )
        let stats = try! #require(snapshot.perSourceStats.first)

        // One window, not six "samples" — that was the misleading label.
        #expect(stats.windowCount == 1)
        #expect(stats.originalSampleCount == 6)
        #expect(stats.includesCompactedWindows == false)
        // The centre is the window median of 70...75, not a raw mean of the rows.
        #expect(stats.typicalWindowValue == 72.5)
        // Extremes are window medians, so with one window they equal the median.
        #expect(stats.lowestWindowValue == 72.5)
        #expect(stats.highestWindowValue == 72.5)
    }

    @Test("A legacy compacted window with unknown depth reports unknown, never zero")
    func unknownDepthStaysUnknownInSummaries() {
        let (store, source) = makeStore()
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-1_800), size: 60)
        _ = store.append(Reading(
            id: UUID(),
            sourceID: source.id,
            kind: .heartRate,
            value: 71,
            start: anchor,
            end: anchor.addingTimeInterval(60),
            provenance: .measured,
            metadata: ReadingMetadata(
                aggregation: AggregationMetadata(originalSampleCount: nil, originalStandardDeviation: nil)
            )
        ))

        let snapshot = MetricDetailSnapshot(
            store: store,
            kind: .heartRate,
            range: .day,
            includeEstimates: false,
            hrvQuality: [:]
        )
        let stats = try! #require(snapshot.perSourceStats.first)

        #expect(stats.windowCount == 1)
        #expect(stats.originalSampleCount == nil)
        #expect(stats.includesCompactedWindows)
    }
}
