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
        /// The synthetic source the blood-pressure trend is written under.
        var estimateSourceID: String
    }

    struct Result: Sendable {
        var vo2Max: [Reading]
        var bloodPressure: [Reading]
        var all: [Reading] { vo2Max + bloodPressure }
    }

    static func compute(
        history: HealthHistory,
        inputs: Inputs,
        now: Date,
        calendar: Calendar = .current
    ) -> Result {
        Result(
            vo2Max: vo2Max(history: history, inputs: inputs, now: now, calendar: calendar),
            bloodPressure: bloodPressure(history: history, inputs: inputs, now: now) ?? []
        )
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
