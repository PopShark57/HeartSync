import Foundation
import Testing
@testable import HeartSyncChecker

/// The Now brief: the facts handed to the on-device model, and the check a generated
/// paragraph must pass before it is shown. The model itself is not exercised here.
@Suite("Now brief")
@MainActor
struct NowBriefTests {
    private let watch = DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit)
    private let strap = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)
    private let ring = DataSource(id: "ring", displayName: "Ring", transport: .bluetooth)
    private let now = Date(timeIntervalSince1970: 1_790_683_200)

    private func row(_ source: DataSource, _ value: Double, _ provenance: Provenance = .measured, age: TimeInterval = 30) -> SourceReadingRow {
        SourceReadingRow(
            source: source,
            value: value,
            provenance: provenance,
            timestamp: now.addingTimeInterval(-age),
            isCurrent: age <= DashboardSnapshot.liveWindow
        )
    }

    private func card(_ kind: MetricKind, _ rows: [SourceReadingRow], headline: Double, severity: DiscrepancySeverity? = nil) -> MetricSummary {
        MetricSummary(
            kind: kind,
            rows: rows,
            headline: headline,
            comparison: severity.map { WindowComparison(severity: $0, spread: 2, sourceCount: rows.count, windowSize: 60) }
        )
    }

    private var metrics: [MetricSummary] {
        [
            card(.spo2, [row(watch, 96, age: 3 * 3_600)], headline: 96),
            card(.heartRate, [row(watch, 71), row(strap, 72)], headline: 71.5, severity: .agreeing),
            card(.bloodPressureSystolic, [row(ring, 118, .estimated, age: 7_200)], headline: 118),
            card(.bloodPressureDiastolic, [row(ring, 76, .estimated, age: 7_200)], headline: 76),
            card(.stress, [row(DataSource(id: AppModel.estimateSourceID, displayName: "HeartSync Estimate", transport: .manual), 42, .estimated)], headline: 42),
        ]
    }

    @Test("Facts come in reading order and carry every card's caveats")
    func factsCarryCaveats() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(facts.lines == [
            "Heart rate is 72 bpm now; 2 devices agree.",
            "Estimated stress level is 42 out of 100 (normal) now, computed by HeartSync.",
            "Estimated blood pressure was 118/76 mmHg when last reported, 2 hours ago.",
            "Blood oxygen was 96% when last reported, 3 hours ago.",
        ])
        #expect(facts.items.map(\.isEstimate) == [false, true, true, false])
        #expect(facts.items.map(\.isCurrent) == [true, true, false, false])
        #expect(facts.items[1].numbers == ["42", "100"])
        #expect(facts.prompt.hasPrefix("Readings:\n- Heart rate is 72 bpm now"))
    }

    @Test("Nothing to describe gives no facts")
    func noCards() {
        #expect(NowBriefFacts.build(metrics: [], stressBand: nil, now: now) == nil)
    }

    @Test("The key ignores a beat of heart rate but not a real change")
    func keyIsCoarse() throws {
        func key(heartRate: Double) throws -> String {
            var cards = metrics
            cards[1].headline = heartRate
            return try #require(NowBriefFacts.build(metrics: cards, stressBand: .normal, now: now)).key
        }
        #expect(try key(heartRate: 71) == key(heartRate: 72))
        #expect(try key(heartRate: 71) != key(heartRate: 85))
    }

    @Test("Drafts the on-device model wrote for these facts are accepted")
    func acceptsGrounded() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let drafts = [
            "Your heart rate is 72 bpm right now. Estimated stress level is 42 out of 100 (normal) now, computed by HeartSync. Estimated blood pressure was 118/76 mmHg 2 hours ago, and blood oxygen was 96% 3 hours ago.",
            "Your heart rate is 72 bpm right now, with 2 devices agreeing. Estimated blood pressure was 118/76 mmHg 2 hours ago, and blood oxygen was 96% 3 hours ago.",
            "Heart rate is 72 bpm now. Estimated stress level is 42 out of 100 now, and SpO2 was 96 % when last reported, three hours ago.",
        ]
        for draft in drafts {
            #expect(NowBriefCheck.accepted(draft, facts: facts) == draft)
        }
        #expect(NowBriefCheck.numbers(in: "36,50 and 118/76, then 7.") == ["36.5", "118", "76", "7"])
    }

    @Test("A number is only accepted about the reading it belongs to")
    func rejectsMisplacedNumbers() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        // Invented.
        #expect(NowBriefCheck.accepted("Your heart rate is 72 bpm, within 60 to 100.", facts: facts) == nil)
        // Real, but another reading's: 96 is blood oxygen, not heart rate.
        #expect(NowBriefCheck.accepted("Your heart rate is 96 bpm.", facts: facts) == nil)
        // An age the stress reading does not have.
        #expect(NowBriefCheck.accepted("Estimated stress level was 42 out of 100 3 hours ago.", facts: facts) == nil)
        // A number before any reading is named.
        #expect(NowBriefCheck.accepted("In the last 24 hours, your heart rate is 72 bpm.", facts: facts) == nil)
    }

    @Test("Estimates are always called estimates, and measurements never are")
    func estimateWording() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefCheck.accepted("Your heart rate is an estimated 72 bpm.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Blood pressure was 118/76 mmHg 2 hours ago.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Estimated blood pressure was 118/76 mmHg 2 hours ago.", facts: facts) != nil)
    }

    @Test("A reading that is not live keeps its age")
    func ageIsKept() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefCheck.accepted("Blood oxygen is 96%.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Blood oxygen was 96% 3 hours ago.", facts: facts) != nil)
    }

    @Test("Judgement, diagnosis, and readings the facts lack reject the paragraph")
    func rejectsJudgementAndDiagnosis() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefCheck.accepted("Your heart rate is a healthy 72 bpm.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Your heart rate is 72 bpm, which is normal.", facts: facts) == nil)
        // The stress band's own word belongs to the stress reading only.
        #expect(NowBriefCheck.accepted("Estimated stress level is 42 out of 100 (normal).", facts: facts) != nil)
        #expect(NowBriefCheck.accepted("Estimated blood pressure of 118/76 mmHg 2 hours ago rules out hypertension.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Consider seeing a doctor about your heart rate of 72 bpm.", facts: facts) == nil)
        // Temperature is not among these facts.
        #expect(NowBriefCheck.accepted("Heart rate is 72 bpm and temperature is steady.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("   ", facts: facts) == nil)
        #expect(NowBriefCheck.accepted(String(repeating: "calm ", count: 200), facts: facts) == nil)
    }

    @Test("Heart rate variability is not read as heart rate")
    func longestNameWins() throws {
        var cards = metrics
        cards.append(card(.hrvSDNN, [row(watch, 48, age: 5_400)], headline: 48))
        let facts = try #require(NowBriefFacts.build(metrics: cards, stressBand: .normal, now: now))
        let split = NowBriefCheck.parts(of: "Heart rate is 72 bpm, and heart rate variability was 48 ms 2 hours ago.", facts: facts)
        #expect(split.parts.map(\.kind) == [.heartRate, .hrvSDNN])
        #expect(!split.unknownReadings)
    }

    @Test("Ages read in whole minutes, hours, or days")
    func ages() {
        #expect(NowBriefFacts.ageText(20) == "1 minute")
        #expect(NowBriefFacts.ageText(25 * 60) == "25 minutes")
        #expect(NowBriefFacts.ageText(3_600) == "1 hour")
        #expect(NowBriefFacts.ageText(5 * 86_400) == "5 days")
    }

    @Test("Without an SDK model or Apple Intelligence there is no brief")
    func unavailableGeneratesNothing() async throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: nil, now: now))
        if !NowBriefGenerator.isAvailable {
            #expect(await NowBriefGenerator.generate(facts) == nil)
        }
    }
}
