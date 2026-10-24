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
        for selection in ["0", "0,1,2", "1,3"] {
            let rendered = try #require(NowBriefGenerator.render(selection: selection, facts: facts))
            #expect(NowBriefCheck.accepted(rendered, facts: facts) == rendered)
        }
        for selection in ["0,0", "2,1", "-1", "99", "0,", "0, and healthy"] {
            #expect(NowBriefGenerator.render(selection: selection, facts: facts) == nil)
        }
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
        #expect(NowBriefCheck.accepted(facts.items[2].sentence, facts: facts) != nil)
    }

    @Test("A reading that is not live keeps its age")
    func ageIsKept() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefCheck.accepted("Blood oxygen is 96%.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted(facts.items[3].sentence, facts: facts) != nil)
    }

    @Test("Judgement, diagnosis, and readings the facts lack reject the paragraph")
    func rejectsJudgementAndDiagnosis() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefCheck.accepted("Your heart rate is a healthy 72 bpm.", facts: facts) == nil)
        #expect(NowBriefCheck.accepted("Your heart rate is 72 bpm, which is normal.", facts: facts) == nil)
        // The stress band's own word belongs to the stress reading only.
        #expect(NowBriefCheck.accepted(facts.items[1].sentence, facts: facts) != nil)
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
        let index = try #require(facts.items.firstIndex(where: { $0.kind == .hrvSDNN }))
        let rendered = try #require(NowBriefGenerator.render(selection: "0,\(index)", facts: facts))
        #expect(rendered.contains("HRV (SDNN)"))
        #expect(rendered.contains("Heart rate is 72 bpm"))
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
        if let reason = NowBriefGenerator.unavailability {
            #expect(!NowBriefGenerator.isAvailable)
            #expect(await NowBriefGenerator.generate(facts) == .unavailable(reason))
        }
    }
    @Test("Units, roles, missing values, pressure order and ages cannot be rewritten")
    func bindsEveryField() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        for draft in [
            "Heart rate is 2 bpm now.", "Heart rate is 72 mmHg now.",
            "Heart rate is bpm now; 2 devices agree.",
            "Estimated blood pressure was 76/118 mmHg when last reported, 2 hours ago.",
            "Estimated blood pressure was 118/76 mmHg when last reported, 76 hours ago."
        ] { #expect(NowBriefCheck.accepted(draft, facts: facts) == nil) }
    }

    @Test("A selection names readings; the model's indices map to their metrics")
    func selectionNamesKinds() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        #expect(NowBriefGenerator.selectedKinds(selection: "0, 2", facts: facts) == [.heartRate, .bloodPressureSystolic])
        #expect(NowBriefGenerator.selectedKinds(selection: "2,0", facts: facts) == nil)
        #expect(facts.rendered([.bodyTemperature]) == nil)
    }

    @Test("A shown brief is always rendered from the current facts")
    func rendersCurrentFacts() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let brief = NowBriefDisplay(kinds: [.heartRate, .bloodPressureSystolic], generatedAt: now)
        #expect(brief.text(for: facts, now: now, available: true) == "\(facts.items[0].sentence) \(facts.items[2].sentence)")

        // A strap moves heart rate between reloads: the brief says what the card says.
        var changed = metrics
        changed[1].headline = 86
        let moved = try #require(NowBriefFacts.build(metrics: changed, stressBand: .normal, now: now))
        #expect(try #require(brief.text(for: moved, now: now, available: true)).hasPrefix("Heart rate is 86 bpm now"))

        // A third device and an older reading change their sentences too.
        changed = metrics
        changed[1].comparison?.sourceCount = 3
        let later = now.addingTimeInterval(3_600)
        let recounted = try #require(NowBriefFacts.build(metrics: changed, stressBand: .normal, now: later))
        let text = try #require(brief.text(for: recounted, now: later, available: true))
        #expect(text.contains("3 devices agree"))
        #expect(text.contains("when last reported, 3 hours ago"))
        #expect(!text.contains("2 hours ago"))
    }

    @Test("A selection is shown only while it is current, available, and among the facts")
    func displayBounds() throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let brief = NowBriefDisplay(kinds: [.heartRate], generatedAt: now)
        #expect(brief.text(for: facts, now: now.addingTimeInterval(NowBriefDisplay.lifetime - 1), available: true) != nil)
        #expect(brief.text(for: facts, now: now.addingTimeInterval(NowBriefDisplay.lifetime), available: true) == nil)
        #expect(brief.text(for: facts, now: now.addingTimeInterval(-1), available: true) == nil)
        #expect(brief.text(for: nil, now: now, available: true) == nil)
        #expect(brief.text(for: facts, now: now, available: false) == nil)
        // The reading it chose has left the screen.
        let withoutHeartRate = try #require(NowBriefFacts.build(metrics: metrics.filter { $0.kind != .heartRate }, stressBand: .normal, now: now))
        #expect(brief.text(for: withoutHeartRate, now: now, available: true) == nil)
    }

    // MARK: Scheduling

    private actor Script {
        private var outcomes: [NowBriefGenerator.Outcome]
        private(set) var calls = 0
        init(_ outcomes: [NowBriefGenerator.Outcome]) { self.outcomes = outcomes }
        func next() async -> NowBriefGenerator.Outcome {
            calls += 1
            // Long enough for the caller's task to be cancelled while the model "runs".
            try? await Task.sleep(for: .milliseconds(50))
            return outcomes.isEmpty ? .noBrief : outcomes.removeFirst()
        }
    }

    private func controller(_ script: Script) -> NowBriefController {
        let now = now
        return NowBriefController(generate: { _ in await script.next() }, clock: { now })
    }

    @Test("A reload that cancels the screen's task does not discard the model's answer")
    func cancellationKeepsTheAnswer() async throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let script = Script([.selected([.heartRate])])
        let brief = controller(script)
        let task = Task { await brief.refresh(facts, unavailability: nil) }
        while !brief.isGenerating { await Task.yield() }
        // A 1 Hz strap changes the facts and SwiftUI cancels the task mid-call.
        task.cancel()
        await task.value
        #expect(brief.display?.kinds == [.heartRate])
        #expect(!brief.isGenerating)
        #expect(await script.calls == 1)
    }

    @Test("Unasked requests wait out the throttle; Regenerate and pull to refresh do not")
    func throttleAndForcedRefresh() async throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let script = Script([.selected([.heartRate]), .noBrief])
        let brief = controller(script)
        await brief.refresh(facts, unavailability: nil)
        #expect(brief.delay(at: now) == NowBriefController.interval)
        #expect(brief.delay(at: now.addingTimeInterval(60)) == NowBriefController.interval - 60)

        // Facts changed within the throttle: the request waits, and a newer key cancels the wait.
        let waiting = Task { await brief.refresh(facts, unavailability: nil) }
        await Task.yield()
        waiting.cancel()
        await waiting.value
        #expect(await script.calls == 1)

        // The person asks: a new key, no wait.
        let before = brief.request(facts: facts, unavailability: nil, now: now)
        brief.requestRefresh()
        #expect(brief.request(facts: facts, unavailability: nil, now: now) != before)
        #expect(brief.delay(at: now) == 0)
        await brief.refresh(facts, unavailability: nil)
        #expect(await script.calls == 2)
        // A declined request keeps the earlier selection, and says it produced none.
        #expect(brief.display?.kinds == [.heartRate])
        #expect(brief.lastOutcome == .noBrief)
    }

    @Test("Nothing is asked without facts or without Apple Intelligence")
    func asksOnlyWhenPossible() async throws {
        let facts = try #require(NowBriefFacts.build(metrics: metrics, stressBand: .normal, now: now))
        let script = Script([.selected([.heartRate])])
        let brief = controller(script)
        await brief.refresh(nil, unavailability: nil)
        await brief.refresh(facts, unavailability: .turnedOff)
        #expect(await script.calls == 0)
        #expect(brief.display == nil)
    }

    @Test("The status line says why there is no brief, and is silent where it cannot run")
    func statusLine() {
        typealias C = NowBriefController
        #expect(C.status(unavailability: .notSupported, isGenerating: false, lastOutcome: .noBrief) == nil)
        #expect(C.status(unavailability: .turnedOff, isGenerating: false, lastOutcome: nil) == .turnedOff)
        #expect(C.status(unavailability: .notReady, isGenerating: false, lastOutcome: nil) == .notReady)
        #expect(C.status(unavailability: nil, isGenerating: true, lastOutcome: .noBrief) == .selecting)
        #expect(C.status(unavailability: nil, isGenerating: false, lastOutcome: .noBrief) == .noBrief)
        #expect(C.status(unavailability: nil, isGenerating: false, lastOutcome: nil) == nil)
        #expect(C.status(unavailability: nil, isGenerating: false, lastOutcome: .selected([.heartRate])) == nil)
    }

    @Test("The renewal period asks again before a steady selection expires")
    func renewalPrecedesExpiry() {
        #expect(NowBriefController.renewalInterval + NowBriefController.interval < NowBriefDisplay.lifetime)
    }
}
