import Foundation
import Testing
@testable import HeartSyncChecker

/// Comparison-only source selection and same-device pair disclosure (improvement 23).
@Suite("Comparison source selection")
struct ComparisonSourceSelectionTests {

    // MARK: - Settings compatibility

    @Test("A settings archive written before this field still decodes")
    func legacySettingsDecode() throws {
        // Build the legacy shape from a real encode rather than by hand, so the fixture
        // cannot drift from the actual wire format of the other fields.
        var withHidden = SettingsSnapshot()
        withHidden.setComparisonHidden(true, forSource: "ring")
        let encoded = try JSONEncoder().encode(withHidden)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["comparisonHiddenSourceIDs"] != nil)

        // Remove it: this is exactly what an archive written by an earlier build looks like.
        object.removeValue(forKey: "comparisonHiddenSourceIDs")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: legacy)

        #expect(decoded.comparisonHiddenSourceIDs == nil)
        #expect(decoded.comparisonHidden.isEmpty)
        // And the rest of the archive round-trips unchanged.
        #expect(decoded.retentionDays == withHidden.retentionDays)
        #expect(decoded.discrepancyThreshold == withHidden.discrepancyThreshold)
        #expect(decoded.ouraSyncInterval == withHidden.ouraSyncInterval)
    }

    @Test("A default snapshot writes no hidden key at all")
    func defaultSnapshotOmitsTheKey() throws {
        let encoded = try JSONEncoder().encode(SettingsSnapshot())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // Nil is omitted, so enabling this feature does not rewrite every user's archive.
        #expect(object["comparisonHiddenSourceIDs"] == nil)
    }

    @Test("Hiding and revealing round-trips, and an empty set stays absent")
    func hiddenSetRoundTrips() throws {
        var snapshot = SettingsSnapshot()
        snapshot.setComparisonHidden(true, forSource: "ring")
        #expect(snapshot.comparisonHidden == ["ring"])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        #expect(decoded.comparisonHidden == ["ring"])

        var cleared = decoded
        cleared.setComparisonHidden(false, forSource: "ring")
        // Back to nil rather than an empty set, so the archive returns to its old shape.
        #expect(cleared.comparisonHiddenSourceIDs == nil)
    }

    // MARK: - Same-device disclosure

    private func source(_ id: String, relationship: String? = nil, transport: SourceTransport = .bluetooth) -> DataSource {
        DataSource(
            id: id,
            displayName: id,
            transport: transport,
            upstreamDeviceRelationshipID: relationship
        )
    }

    private func analyses(_ readings: [Reading], range: DateInterval) -> [PairwiseAnalysis] {
        ComparisonEngine.allPairwiseAnalyses(from: readings, range: range, minimumPairedWindows: 1)
    }

    @Test("Two transports of one device are identified as a same-device pair")
    func sameDevicePairIsIdentified() {
        let anchor = Date(timeIntervalSince1970: 1_699_999_980)
        let range = DateInterval(start: anchor.addingTimeInterval(-60), end: anchor.addingTimeInterval(600))
        let readings = [
            Reading(sourceID: "ring.ble", kind: .heartRate, value: 70, start: anchor.addingTimeInterval(5)),
            Reading(sourceID: "ring.health", kind: .heartRate, value: 71, start: anchor.addingTimeInterval(6)),
        ]
        let sources = [
            source("ring.ble", relationship: "ring-serial-1"),
            source("ring.health", relationship: "ring-serial-1", transport: .healthKit),
        ]
        let results = analyses(readings, range: range)
        let keys = PairwiseEvidenceOverview.sameDevicePairKeys(analyses: results, sources: sources)

        #expect(results.count == 1)
        #expect(keys.count == 1)

        let overview = PairwiseEvidenceOverview(analyses: results, sameDevicePairs: keys)
        #expect(overview.sameDevicePairCount == 1)
        // The pair is still present and inspectable — it is disclosed, not removed.
        #expect(results.first?.observations.isEmpty == false)
    }

    @Test("Independent devices are never merged, and unknown identity stays unknown")
    func independentDevicesAreNotMerged() {
        let anchor = Date(timeIntervalSince1970: 1_699_999_980)
        let range = DateInterval(start: anchor.addingTimeInterval(-60), end: anchor.addingTimeInterval(600))
        let readings = [
            Reading(sourceID: "strap", kind: .heartRate, value: 70, start: anchor.addingTimeInterval(5)),
            Reading(sourceID: "ring", kind: .heartRate, value: 71, start: anchor.addingTimeInterval(6)),
        ]
        let results = analyses(readings, range: range)

        // Same display name and model, but no confirmed relationship: still two devices.
        var lookalikeA = source("strap")
        var lookalikeB = source("ring")
        lookalikeA.displayName = "Heart Monitor"
        lookalikeB.displayName = "Heart Monitor"
        lookalikeA.model = "HM-1"
        lookalikeB.model = "HM-1"

        let keys = PairwiseEvidenceOverview.sameDevicePairKeys(
            analyses: results,
            sources: [lookalikeA, lookalikeB]
        )
        #expect(keys.isEmpty)
        #expect(PairwiseEvidenceOverview(analyses: results, sameDevicePairs: keys).sameDevicePairCount == 0)
    }

    @Test("A relationship on only one side is not a confirmed pair")
    func oneSidedRelationshipIsNotAPair() {
        let anchor = Date(timeIntervalSince1970: 1_699_999_980)
        let range = DateInterval(start: anchor.addingTimeInterval(-60), end: anchor.addingTimeInterval(600))
        let readings = [
            Reading(sourceID: "a", kind: .heartRate, value: 70, start: anchor.addingTimeInterval(5)),
            Reading(sourceID: "b", kind: .heartRate, value: 71, start: anchor.addingTimeInterval(6)),
        ]
        let keys = PairwiseEvidenceOverview.sameDevicePairKeys(
            analyses: analyses(readings, range: range),
            sources: [source("a", relationship: "ring-1"), source("b")]
        )
        #expect(keys.isEmpty)
    }
}
