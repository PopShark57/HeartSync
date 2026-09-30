import Foundation

/// HeartSync's own estimates, computed from a read of history and nothing else.
///
/// A pure function over a `HealthHistory`, so `AppModel` runs it off the main actor and
/// then only reconciles and writes the result there, and a test can call it directly.
/// Estimates stay estimates: every reading here is `.estimated` and carries
/// `ReadingMetadata.heartSyncModel`.
enum DerivedEstimates {
    struct Inputs: Sendable {
        var vo2MaxEnabled: Bool
        /// From the user's age; nil means no VO\u{2082} max estimate can be made.
        var estimatedMaxHeartRate: Double?
        /// Only when the trend index is enabled and calibrated.
        var bloodPressureCalibration: UserProfile.BPCalibration?
        /// The synthetic source the blood-pressure trend and the stress index are written under.
        var estimateSourceID: String
        /// The user's own history, summarised for the stress index. Nil means build it now.
        var stressBaseline: StressModel.Baseline? = nil
    }

    struct Result: Sendable {
        var vo2Max: [Reading]
        var bloodPressure: [Reading]
        /// At most one reading: the stress index for the current five-minute slot.
        var stress: [Reading] = []
        /// Why there is or is not a stress index now; nil only when it was not computed.
        var stressAssessment: Swift.Result<StressModel.Assessment, StressModel.Unavailable>?
        /// The baseline the stress index used, so the caller can reuse it.
        var stressBaseline: StressModel.Baseline?
        var all: [Reading] { vo2Max + bloodPressure + stress }
    }

    static func compute(
        history: HealthHistory,
        inputs: Inputs,
        now: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> Result {
        let baseline = inputs.stressBaseline.flatMap {
            $0.isStale(at: now, utcOffset: timeZone.secondsFromGMT(for: now)) ? nil : $0
        } ?? StressModel.Baseline.build(
            history: history,
            now: now,
            estimateSourceID: inputs.estimateSourceID,
            timeZone: timeZone
        )
        let stress = stress(history: history, inputs: inputs, baseline: baseline, now: now, timeZone: timeZone)
        return Result(
            vo2Max: vo2Max(history: history, inputs: inputs, now: now, calendar: calendar),
            bloodPressure: bloodPressure(history: history, inputs: inputs, now: now) ?? [],
            stress: stress.reading.map { [$0] } ?? [],
            stressAssessment: stress.assessment,
            stressBaseline: baseline
        )
    }

    /// The stress index for the current five-minute slot, smoothed with the last slot's.
    ///
    /// The previous score is read only from slots before the current one, so recomputing
    /// inside one slot revises its value rather than blending it with itself.
    static func stress(
        history: HealthHistory,
        inputs: Inputs,
        baseline: StressModel.Baseline,
        now: Date,
        timeZone: TimeZone = .current
    ) -> (reading: Reading?, assessment: Swift.Result<StressModel.Assessment, StressModel.Unavailable>) {
        let slot = StressModel.slot(at: now)
        let stamp = Date(timeIntervalSince1970: Double(slot) * StressModel.slotLength)
        let earlier = DateInterval(
            start: now.addingTimeInterval(-StressModel.smoothingHorizon),
            end: stamp.addingTimeInterval(-0.001)
        )
        let previous = (history.latestOutcome(kind: .stress, sourceID: inputs.estimateSourceID, midpointIn: earlier).value ?? nil)
            .map { (score: $0.value, at: $0.end) }
        let assessment = StressModel.assess(
            history: history,
            baseline: baseline,
            now: now,
            maxHeartRate: inputs.estimatedMaxHeartRate,
            estimateSourceID: inputs.estimateSourceID,
            previous: previous,
            timeZone: timeZone
        )
        guard case .success(let result) = assessment else { return (nil, assessment) }
        let reading = Reading(
            id: UUID(stableFrom: "derived.stress.\(slot)"),
            sourceID: inputs.estimateSourceID,
            kind: .stress,
            value: (result.score * 10).rounded() / 10,
            start: stamp,
            provenance: .estimated,
            metadata: ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)
        )
        return (reading, assessment)
    }

    /// A VO\u{2082} max estimate per source that reports resting heart rate but no measured
    /// VO\u{2082} max of its own.
    ///
    /// Sources that measure VO\u{2082} max directly (an Apple Watch does) are skipped: replacing
    /// or duplicating a real measurement with a model would be worse data, and comparing a
    /// device against an estimate derived from itself is circular.
    static func vo2Max(
        history: HealthHistory,
        inputs: Inputs,
        now: Date,
        calendar: Calendar = .current
    ) -> [Reading] {
        guard inputs.vo2MaxEnabled, let maxHR = inputs.estimatedMaxHeartRate else { return [] }
        let window = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)

        // One read of each kind for all sources, not one per source.
        let measuredSources = Set(
            history.readings(kind: .vo2Max, in: window)
                .filter { $0.provenance == .measured }
                .map(\.sourceID)
        )
        let restingReadings = history.readings(kind: .restingHeartRate, in: window)

        var result: [Reading] = []
        for source in history.enabledSources {
            if measuredSources.contains(source.id) { continue }
            guard let latest = restingReadings.last(where: { $0.sourceID == source.id }),
                  let value = Estimators.vo2Max(restingHeartRate: latest.value, maxHeartRate: maxHR)
            else { continue }

            // One estimate per source per day; the id makes repeats collapse.
            let day = calendar.startOfDay(for: latest.end)
            result.append(Reading(
                id: UUID(stableFrom: "derived.vo2.\(source.id).\(Int(day.timeIntervalSince1970))"),
                sourceID: source.id,
                kind: .vo2Max,
                value: value,
                start: day,
                end: day.addingTimeInterval(86_400),
                provenance: .estimated,
                metadata: ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)
            ))
        }
        return result
    }

    /// The blood-pressure trend index, when the user has enabled it and calibrated it.
    static func bloodPressure(history: HealthHistory, inputs: Inputs, now: Date) -> [Reading]? {
        guard let calibration = inputs.bloodPressureCalibration,
              let latestHR = currentHeartRate(history: history, now: now),
              let estimate = Estimators.bloodPressure(
                  calibration: calibration,
                  currentHeartRate: latestHR,
                  currentRMSSD: currentRMSSD(history: history, now: now),
                  now: now
              )
        else { return nil }

        // Quantise the timestamp to five minutes so repeated recomputation within a window
        // updates one reading rather than accumulating dozens.
        let slot = Int(now.timeIntervalSince1970 / 300)
        let stamp = Date(timeIntervalSince1970: Double(slot) * 300)
        let metadata = ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)
        return [
            Reading(
                id: UUID(stableFrom: "derived.bp.sys.\(slot)"),
                sourceID: inputs.estimateSourceID,
                kind: .bloodPressureSystolic,
                value: estimate.systolic,
                start: stamp,
                provenance: .estimated,
                metadata: metadata
            ),
            Reading(
                id: UUID(stableFrom: "derived.bp.dia.\(slot)"),
                sourceID: inputs.estimateSourceID,
                kind: .bloodPressureDiastolic,
                value: estimate.diastolic,
                start: stamp,
                provenance: .estimated,
                metadata: metadata
            ),
        ]
    }

    /// Consensus heart rate of the latest window in the last ten minutes, across every
    /// enabled source: the index describes the user's state, not one device's opinion of it.
    static func currentHeartRate(history: HealthHistory, now: Date) -> Double? {
        let recent = DateInterval(start: now.addingTimeInterval(-600), end: now)
        return ComparisonEngine.windows(from: history.readings(kind: .heartRate, in: recent), kind: .heartRate)
            .last?.consensus
    }

    /// Consensus RMSSD of the latest window in the last hour.
    static func currentRMSSD(history: HealthHistory, now: Date) -> Double? {
        let recent = DateInterval(start: now.addingTimeInterval(-3_600), end: now)
        return ComparisonEngine.windows(from: history.readings(kind: .hrvRMSSD, in: recent), kind: .hrvRMSSD)
            .last?.consensus
    }
}
