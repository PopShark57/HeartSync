import Foundation
import Testing
@testable import HeartSyncChecker

/// Removal confirmations state what would be deleted before anything is (improvement 26).
///
/// The dialog itself is covered by a UI test; these pin the numbers it reads from the store
/// and the wording it builds from them.
@Suite("Source removal confirmation")
@MainActor
struct SourceRemovalTests {

    private let strap = DataSource(id: "strap", displayName: "Polar H10", transport: .bluetooth)
    private let watch = DataSource(id: "hk.com.apple.health", displayName: "Apple Watch", transport: .healthKit)

    private func makeStore(strapReadings: Int = 5, watchReadings: Int = 3) -> (HealthStore, Date) {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        store.upsert(watch)
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-7_200), size: 60)
        for index in 0..<strapReadings {
            _ = store.append(Reading(
                sourceID: strap.id,
                kind: .heartRate,
                value: 70,
                start: anchor.addingTimeInterval(Double(index) * 60)
            ))
        }
        for index in 0..<watchReadings {
            _ = store.append(Reading(
                sourceID: watch.id,
                kind: .heartRate,
                value: 72,
                start: anchor.addingTimeInterval(Double(index) * 60 + 600)
            ))
        }
        return (store, anchor)
    }

    // MARK: - Store numbers

    @Test("The summary counts exactly the rows a removal would delete, and when they start")
    func summaryCountsOnlyThatSource() throws {
        let (store, anchor) = makeStore()

        let strapHistory = try store.sourceHistorySummaryOutcome(sourceID: strap.id).get()
        #expect(strapHistory.readingCount == 5)
        #expect(strapHistory.earliest == anchor)

        let watchHistory = try store.sourceHistorySummaryOutcome(sourceID: watch.id).get()
        #expect(watchHistory.readingCount == 3)
        #expect(watchHistory.earliest == anchor.addingTimeInterval(600))

        // Removing one source deletes that count and leaves the other untouched.
        #expect(store.remove(sourceID: strap.id))
        #expect(try store.sourceHistorySummaryOutcome(sourceID: strap.id).get().readingCount == 0)
        #expect(try store.sourceHistorySummaryOutcome(sourceID: watch.id).get().readingCount == 3)
        #expect(store.readingCount == 3)
    }

    @Test("A source with nothing stored reports zero and no start date")
    func emptySourceIsZero() throws {
        let (store, _) = makeStore(strapReadings: 0)
        let history = try store.sourceHistorySummaryOutcome(sourceID: strap.id).get()
        #expect(history.readingCount == 0)
        #expect(history.earliest == nil)
    }

    @Test("A failed count is a failure, never a zero")
    func failedCountIsNotZero() {
        let (store, _) = makeStore()
        store.injectQueryFailureForTesting()
        let outcome = store.sourceHistorySummaryOutcome(sourceID: strap.id)
        #expect(outcome.isFailure)
        #expect(outcome.value == nil)
    }

    @Test("The export offered before removal contains only that source's rows")
    func perSourceExportIsScoped() throws {
        let (store, _) = makeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-removal-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("strap.csv")
        let rows = try store.writeExportCSV(to: url, sourceID: strap.id, pageSize: 2)
        #expect(rows == 5)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\r\n", omittingEmptySubsequences: true)
        #expect(lines.count == 6)
        #expect(lines.dropFirst().allSatisfy { $0.contains(",strap,") })
        #expect(lines.dropFirst().contains { $0.contains(watch.id) } == false)
    }

    // MARK: - Wording

    @Test("A Bluetooth removal states the count, the source, and that it cannot come back")
    func bluetoothWording() {
        let consequence = SourceRemovalConsequence.make(
            action: .removeSource,
            source: strap,
            history: .init(readingCount: 48_210, earliest: Date.now.addingTimeInterval(-86_400 * 3))
        )
        #expect(consequence.title == "Remove Polar H10?")
        #expect(consequence.message.contains(48_210.formatted()))
        #expect(consequence.message.contains("readings from Polar H10 recorded since"))
        #expect(consequence.message.contains("Bluetooth history cannot be downloaded again."))
        #expect(consequence.confirmTitle == "Remove and delete readings")
        #expect(consequence.offersExport)
    }

    @Test("An Apple Health removal says Health keeps its copy but HeartSync will not re-import it")
    func healthKitWording() {
        let consequence = SourceRemovalConsequence.make(
            action: .removeSource,
            source: watch,
            history: .init(readingCount: 1, earliest: .now)
        )
        #expect(consequence.message.contains("Deletes 1 reading from Apple Watch"))
        #expect(consequence.message.contains("Apple Health keeps its own copy"))
        #expect(consequence.message.contains("does not import these samples again"))
    }

    @Test("Nothing stored means nothing is claimed to be deleted")
    func emptyHistoryWording() {
        let consequence = SourceRemovalConsequence.make(
            action: .removeSource,
            source: strap,
            history: .init(readingCount: 0, earliest: nil)
        )
        #expect(consequence.message.hasPrefix("No readings from Polar H10 are stored"))
        #expect(consequence.confirmTitle == "Remove device")
        #expect(consequence.offersExport == false)
    }

    @Test("An unreadable count is reported as unknown and still treated as a deletion")
    func unknownCountWording() {
        let consequence = SourceRemovalConsequence.make(action: .removeSource, source: strap, history: nil)
        #expect(consequence.message.contains("could not count"))
        #expect(consequence.message.contains("deletes all of them"))
        #expect(consequence.confirmTitle == "Remove and delete readings")
        #expect(consequence.offersExport)
    }

    @Test("Disconnecting Oura says it signs out and how much history a resync restores")
    func ouraWording() {
        let oura = DataSource(id: DataSource.ouraSourceID, displayName: "Oura Ring", transport: .oura)
        let withHistory = SourceRemovalConsequence.make(
            action: .disconnectOura,
            source: oura,
            history: .init(readingCount: 320, earliest: .now)
        )
        #expect(withHistory.title == "Disconnect Oura?")
        #expect(withHistory.message.contains("signs out of Oura"))
        #expect(withHistory.message.contains("last \(SourceRemovalConsequence.ouraResyncDays) days"))
        #expect(withHistory.confirmTitle == "Disconnect and delete readings")

        let noHistory = SourceRemovalConsequence.make(action: .disconnectOura, source: nil, history: nil)
        #expect(noHistory.message.hasPrefix("No Oura readings are stored"))
        #expect(noHistory.confirmTitle == "Disconnect")
        #expect(noHistory.offersExport == false)
    }
}
