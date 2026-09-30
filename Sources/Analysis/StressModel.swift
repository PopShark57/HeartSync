import Foundation

/// Count, sum, and sum of squares of one metric's values in one local hour of day.
struct HourMoments: Sendable, Equatable {
    var count: Int
    var sum: Double
    var sumOfSquares: Double

    static let zero = HourMoments(count: 0, sum: 0, sumOfSquares: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        HourMoments(count: lhs.count + rhs.count, sum: lhs.sum + rhs.sum, sumOfSquares: lhs.sumOfSquares + rhs.sumOfSquares)
    }

    var mean: Double? { count > 0 ? sum / Double(count) : nil }

    /// Sample standard deviation, or nil below two values.
    var standardDeviation: Double? {
        guard count > 1, let mean else { return nil }
        let variance = (sumOfSquares - Double(count) * mean * mean) / Double(count - 1)
        return variance > 0 ? variance.squareRoot() : 0
    }
}

/// HeartSync's stress index: a 0–100 estimate of physiological arousal right now, relative to
/// the user's own recent baseline.
///
/// **An estimate, never a measurement.** No consumer device measures stress. What a device can
/// report are signals that move with autonomic arousal, and each of them also moves for other
/// reasons: exercise, caffeine, alcohol, illness, heat, posture, poor sensor contact. The model
/// therefore compares every signal with the same person's own history rather than with a
/// population, weights the signals by how directly they track sympathetic activity, discounts
/// stale or thinly supported evidence, and refuses to score at all when heart rate says the
/// person is most likely exercising. Readings are stored as `.estimated` under the HeartSync
/// estimate source and never enter a device-agreement verdict.
///
/// Signals, each turned into a robust z-score (positive means more stress-like):
///
/// 1. **Vagal withdrawal (HRV), weight 0.40.** HRV falls as parasympathetic tone is withdrawn
///    under stress. Every device reports HRV on its own scale (RMSSD from R–R intervals, SDNN
///    from Apple Watch, a night's average from Oura), so each source is scored against its own
///    30-day history of ln(HRV): median and MAD, which a few artefact-ridden windows cannot
///    drag. Sources are pooled by freshness.
/// 2. **Heart-rate elevation, weight 0.30.** Heart rate against the user's own heart rate at
///    the same time of day (the three surrounding local hours over the last 14 days), so the
///    ordinary daytime rise over the night is not read as stress. With too little history it
///    falls back to resting heart rate plus a waking allowance, at half weight.
/// 3. **Respiration, weight 0.10.** Breathing rate above its 30-day baseline.
/// 4. **Thermal strain, weight 0.08.** Temperature above each source's own baseline. Only a
///    rise counts.
/// 5. **Oxygenation, weight 0.07.** SpO₂ below its baseline. Only a fall counts.
///
/// The weighted mean of the clamped z-scores goes through a logistic curve, is pulled
/// towards the typical score in proportion to how little evidence there was, and is smoothed
/// with the previous score from the last 20 minutes. An exercise gate uses heart-rate reserve
/// (Karvonen): above half of reserve no score is produced, and between 30% and 50% the heart
/// rate and HRV terms fade out, because exertion lowers HRV and raises heart rate for reasons
/// that are not stress. Blood pressure is deliberately not an input: HeartSync's own blood
/// pressure is modelled from heart rate and HRV, and a ring's is a vendor model, so using it
/// would count the same evidence twice.
enum StressModel {

    // MARK: Robust statistics

    /// Median and scaled median absolute deviation.
    struct Robust: Sendable, Equatable {
        var median: Double
        /// 1.4826 × MAD, which estimates the standard deviation of normal data.
        var scale: Double
        var count: Int

        init?(_ values: [Double], minimumCount: Int = 8) {
            guard values.count >= minimumCount else { return nil }
            let sorted = values.sorted()
            let median = Self.median(ofSorted: sorted)
            let deviations = sorted.map { abs($0 - median) }.sorted()
            self.median = median
            self.scale = 1.4826 * Self.median(ofSorted: deviations)
            self.count = values.count
        }

        init(median: Double, scale: Double, count: Int) {
            self.median = median
            self.scale = scale
            self.count = count
        }

        /// How many scales `value` sits above the median, with a floor on the scale so a
        /// suspiciously steady history cannot turn a small change into a huge score.
        func z(_ value: Double, minimumScale: Double) -> Double {
            (value - median) / max(scale, minimumScale)
        }

        private static func median(ofSorted values: [Double]) -> Double {
            let middle = values.count / 2
            return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        }
    }

    // MARK: Baseline

    /// Identifies one source's HRV series. RMSSD and SDNN from the same device are different
    /// quantities and keep separate baselines.
    struct HRVKey: Hashable, Sendable {
        var sourceID: String
        var kind: MetricKind
    }

    /// The user's own history, summarised. Rebuilt every few hours: it describes weeks, so
    /// rebuilding it every five minutes would re-read history for no change.
    struct Baseline: Sendable, Equatable {
        /// ln(HRV) per source and HRV metric, over 30 days.
        var hrv: [HRVKey: Robust] = [:]
        /// Heart rate by local hour of day (0–23), over 14 days.
        var heartRateByHour: [Int: HourMoments] = [:]
        /// Median resting heart rate over 30 days, from any source.
        var restingHeartRate: Double?
        var respiratoryRate: Robust?
        /// Temperature per source: a ring's finger reading and a thermometer differ in level.
        var temperature: [String: Robust] = [:]
        var spo2: Robust?
        var builtAt: Date
        /// The UTC offset `heartRateByHour` was bucketed with.
        var utcOffset: Int

        static let hrvSpan: TimeInterval = 30 * 86_400
        static let heartRateSpan: TimeInterval = 14 * 86_400
        /// How long a baseline is reused before it is rebuilt.
        static let lifetime: TimeInterval = 6 * 3_600

        func isStale(at now: Date, utcOffset: Int) -> Bool {
            now.timeIntervalSince(builtAt) > Self.lifetime || now < builtAt || utcOffset != self.utcOffset
        }

        /// Heart rate at this local hour, pooled with the hours either side so one hour's
        /// few samples do not make the baseline jumpy. Nil below 60 samples.
        func heartRateNorm(atLocalHour hour: Int) -> (mean: Double, sd: Double)? {
            let pooled = [(hour + 23) % 24, hour, (hour + 1) % 24]
                .map { heartRateByHour[$0] ?? .zero }
                .reduce(.zero, +)
            guard pooled.count >= 60, let mean = pooled.mean, let sd = pooled.standardDeviation else { return nil }
            return (mean, sd)
        }

        /// Reads history once and summarises it. A failed read leaves that part empty; the
        /// assessment then has less evidence and says so through its confidence.
        static func build(
            history: HealthHistory,
            now: Date,
            estimateSourceID: String,
            timeZone: TimeZone = .current
        ) -> Baseline {
            let utcOffset = timeZone.secondsFromGMT(for: now)
            var baseline = Baseline(builtAt: now, utcOffset: utcOffset)
            let month = DateInterval(start: now.addingTimeInterval(-hrvSpan), end: now)

            func usable(_ kind: MetricKind) -> [Reading] {
                history.readings(kind: kind, in: month).filter {
                    $0.sourceID != estimateSourceID && $0.metadata?.modelledBy == nil && $0.isPlausible
                }
            }

            for kind in [MetricKind.hrvRMSSD, .hrvSDNN] {
                let bySource = Dictionary(grouping: usable(kind).filter { $0.value > 0 }, by: \.sourceID)
                for (sourceID, readings) in bySource {
                    if let robust = Robust(readings.map { log($0.value) }) {
                        baseline.hrv[HRVKey(sourceID: sourceID, kind: kind)] = robust
                    }
                }
            }

            let hourRange = DateInterval(start: now.addingTimeInterval(-heartRateSpan), end: now)
            baseline.heartRateByHour = history.hourOfDayMomentsOutcome(
                kind: .heartRate,
                range: hourRange,
                utcOffset: utcOffset,
                maximumDuration: MetricKind.heartRate.comparisonWindow
            ).value ?? [:]

            let resting = usable(.restingHeartRate).map(\.value)
            baseline.restingHeartRate = Robust(resting, minimumCount: 3)?.median
            baseline.respiratoryRate = Robust(usable(.respiratoryRate).filter { $0.provenance != .estimated }.map(\.value))
            baseline.spo2 = Robust(usable(.spo2).filter { $0.provenance != .estimated }.map(\.value))
            for (sourceID, readings) in Dictionary(grouping: usable(.bodyTemperature), by: \.sourceID) {
                if let robust = Robust(readings.map(\.value)) { baseline.temperature[sourceID] = robust }
            }
            return baseline
        }
    }

    // MARK: Assessment

    enum Signal: String, CaseIterable, Sendable {
        case vagalWithdrawal
        case heartRateElevation
        case respiration
        case thermalStrain
        case oxygenation

        /// The signal's share of the score when every signal is present.
        var weight: Double {
            switch self {
            case .vagalWithdrawal:    0.40
            case .heartRateElevation: 0.30
            case .respiration:        0.10
            case .thermalStrain:      0.08
            case .oxygenation:        0.07
            }
        }

        /// Plain wording for a driver: what was unusual, in the direction that raises stress.
        var raisedDescription: String {
            switch self {
            case .vagalWithdrawal:    "HRV below your usual"
            case .heartRateElevation: "heart rate above your usual for this time of day"
            case .respiration:        "breathing faster than usual"
            case .thermalStrain:      "temperature above your usual"
            case .oxygenation:        "blood oxygen below your usual"
            }
        }

        var loweredDescription: String {
            switch self {
            case .vagalWithdrawal:    "HRV above your usual"
            case .heartRateElevation: "heart rate below your usual for this time of day"
            case .respiration:        "breathing slower than usual"
            case .thermalStrain:      "temperature at your usual"
            case .oxygenation:        "blood oxygen at your usual"
            }
        }
    }

    struct Component: Sendable, Equatable {
        var signal: Signal
        /// Robust z-score, clamped to ±3. Positive means more stress-like.
        var z: Double
        /// The weight this component actually carried: the signal's weight times freshness,
        /// baseline quality, and the exercise fade.
        var weight: Double
    }

    enum Band: String, Sendable, CaseIterable {
        case low, normal, elevated, high

        init(score: Double) {
            switch score {
            case ..<25: self = .low
            case ..<50: self = .normal
            case ..<75: self = .elevated
            default:    self = .high
            }
        }

        var title: String {
            switch self {
            case .low:      String(localized: "stress.band.low", defaultValue: "Low", comment: "Stress index band, 0 to 24")
            case .normal:   String(localized: "stress.band.normal", defaultValue: "Normal", comment: "Stress index band, 25 to 49")
            case .elevated: String(localized: "stress.band.elevated", defaultValue: "Elevated", comment: "Stress index band, 50 to 74")
            case .high:     String(localized: "stress.band.high", defaultValue: "High", comment: "Stress index band, 75 to 100")
            }
        }
    }

    struct Assessment: Sendable, Equatable {
        var score: Double
        var band: Band
        var components: [Component]
        /// 0–1: how much of the full evidence was available, fresh, and well baselined.
        var confidence: Double
        var heartRate: Double?
        var assessedAt: Date

        /// The two components that pushed the score furthest from typical, strongest first.
        var drivers: [Component] {
            components
                .filter { abs($0.z) >= 0.75 }
                .sorted { abs($0.z) * $0.weight > abs($1.z) * $1.weight }
                .prefix(2)
                .map { $0 }
        }

        /// "Mostly HRV below your usual and heart rate above your usual for this time of day",
        /// or nil when nothing stood out.
        var driverSummary: String? {
            let parts = drivers.map { $0.z > 0 ? $0.signal.raisedDescription : $0.signal.loweredDescription }
            guard !parts.isEmpty else { return nil }
            return "Mostly " + parts.joined(separator: " and ")
        }
    }

    enum Unavailable: Error, Sendable, Equatable {
        /// Neither a current heart rate nor a current HRV.
        case noCurrentSignal
        /// Heart rate is above half of heart-rate reserve: most likely exercise, not stress.
        case likelyExercise(heartRate: Double)
        /// Some signal exists, but too little of it is baselined to say anything.
        case insufficientEvidence
    }

    // MARK: Parameters

    static let heartRateMaxAge: TimeInterval = 15 * 60
    static let rmssdMaxAge: TimeInterval = 90 * 60
    /// Apple Watch records SDNN every few hours; an Oura night's average ends at waking.
    static let sdnnMaxAge: TimeInterval = 4 * 3_600
    static let respirationMaxAge: TimeInterval = 6 * 3_600
    static let temperatureMaxAge: TimeInterval = 12 * 3_600
    static let spo2MaxAge: TimeInterval = 6 * 3_600
    /// A previous score this recent is blended in, so one noisy window cannot swing it.
    static let smoothingHorizon: TimeInterval = 20 * 60
    static let smoothingWeight = 0.35
    static let exerciseFadeStart = 0.30
    static let exerciseCutoff = 0.50
    /// Beats per minute a waking heart rate typically sits above resting, for the fallback
    /// heart-rate norm.
    static let wakingAllowance = 10.0
    /// Below this total weight the evidence is too thin to score.
    static let minimumEvidence = 0.25
    static let logisticSlope = 1.25
    static let logisticCentre = 0.4

    /// The score a person exactly at their baseline gets (about 38).
    static var typicalScore: Double { logistic(0) }

    static func logistic(_ z: Double) -> Double {
        100 / (1 + exp(-logisticSlope * (z - logisticCentre)))
    }

    /// Freshness of evidence `age` old, where `maxAge` is the oldest still usable: 1 when
    /// new, 0.5 at half `maxAge`, gone past it.
    static func freshness(age: TimeInterval, maxAge: TimeInterval) -> Double {
        guard age <= maxAge else { return 0 }
        return exp(-max(0, age) * log(2) / (maxAge / 2))
    }

    // MARK: Scoring

    /// Scores the user's current state from `history` against `baseline`.
    ///
    /// - Parameters:
    ///   - maxHeartRate: the user's maximum heart rate for the exercise gate; age-predicted
    ///     when known, otherwise a conservative 190.
    ///   - previous: the last stored score and when it was computed, for smoothing.
    static func assess(
        history: HealthHistory,
        baseline: Baseline,
        now: Date,
        maxHeartRate: Double?,
        estimateSourceID: String,
        previous: (score: Double, at: Date)? = nil,
        timeZone: TimeZone = .current
    ) -> Result<Assessment, Unavailable> {
        let recent = { (kind: MetricKind, age: TimeInterval) -> [Reading] in
            history.readings(kind: kind, in: DateInterval(start: now.addingTimeInterval(-age), end: now.addingTimeInterval(60)))
                .filter { $0.sourceID != estimateSourceID && $0.metadata?.modelledBy == nil && $0.isPlausible }
        }

        // Current heart rate: the consensus of the newest comparison window, across devices.
        let heartRateReadings = recent(.heartRate, heartRateMaxAge)
        let heartRate = ComparisonEngine.windows(from: heartRateReadings, kind: .heartRate).last?.consensus
            ?? heartRateReadings.filter { $0.provenance != .estimated }.max { $0.end < $1.end }?.value

        // Exercise gate (Karvonen heart-rate reserve).
        let hour = localHour(of: now, utcOffset: timeZone.secondsFromGMT(for: now))
        let norm = baseline.heartRateNorm(atLocalHour: hour)
        let resting = baseline.restingHeartRate ?? norm.map { $0.mean - wakingAllowance } ?? 62
        let maximum = max(maxHeartRate ?? 190, resting + 40)
        var exerciseFade = 1.0
        if let heartRate {
            let reserve = (heartRate - resting) / (maximum - resting)
            if reserve >= exerciseCutoff { return .failure(.likelyExercise(heartRate: heartRate)) }
            if reserve > exerciseFadeStart {
                exerciseFade = 1 - (reserve - exerciseFadeStart) / (exerciseCutoff - exerciseFadeStart)
            }
        }

        var components: [Component] = []

        // 1. HRV, per source against its own baseline, pooled by freshness.
        var hrvWeighted = 0.0
        var hrvFreshness = 0.0
        var bestHRVFreshness = 0.0
        for (kind, maxAge) in [(MetricKind.hrvRMSSD, rmssdMaxAge), (.hrvSDNN, sdnnMaxAge)] {
            let latest = Dictionary(grouping: recent(kind, maxAge).filter { $0.value > 0 }, by: \.sourceID)
                .compactMapValues { $0.max { $0.end < $1.end } }
            for (sourceID, reading) in latest {
                guard let robust = baseline.hrv[HRVKey(sourceID: sourceID, kind: kind)] else { continue }
                let fresh = freshness(age: now.timeIntervalSince(reading.end), maxAge: maxAge)
                guard fresh > 0 else { continue }
                // Lower HRV is more stress-like, so the sign is flipped.
                let z = -robust.z(log(reading.value), minimumScale: 0.08)
                hrvWeighted += fresh * clamp(z)
                hrvFreshness += fresh
                bestHRVFreshness = max(bestHRVFreshness, fresh * min(1, Double(robust.count) / 20))
            }
        }
        if hrvFreshness > 0 {
            components.append(Component(
                signal: .vagalWithdrawal,
                z: hrvWeighted / hrvFreshness,
                weight: Signal.vagalWithdrawal.weight * bestHRVFreshness * exerciseFade
            ))
        }

        // 2. Heart rate against the same hours of the day, or resting plus a waking allowance.
        if let heartRate {
            if let norm {
                components.append(Component(
                    signal: .heartRateElevation,
                    z: clamp((heartRate - norm.mean) / max(norm.sd, 4)),
                    weight: Signal.heartRateElevation.weight * exerciseFade
                ))
            } else if let restingBaseline = baseline.restingHeartRate {
                let expected = restingBaseline + wakingAllowance
                components.append(Component(
                    signal: .heartRateElevation,
                    z: clamp((heartRate - expected) / max(6, 0.12 * restingBaseline)),
                    weight: Signal.heartRateElevation.weight * 0.5 * exerciseFade
                ))
            }
        }

        // 3. Respiration.
        if let robust = baseline.respiratoryRate,
           let reading = recent(.respiratoryRate, respirationMaxAge).filter({ $0.provenance != .estimated }).max(by: { $0.end < $1.end }) {
            let fresh = freshness(age: now.timeIntervalSince(reading.end), maxAge: respirationMaxAge)
            components.append(Component(
                signal: .respiration,
                z: clamp(robust.z(reading.value, minimumScale: 0.7)),
                weight: Signal.respiration.weight * fresh
            ))
        }

        // 4. Temperature: a rise only, against each source's own level.
        let temperatures = Dictionary(grouping: recent(.bodyTemperature, temperatureMaxAge), by: \.sourceID)
            .compactMapValues { $0.max { $0.end < $1.end } }
        let thermal = temperatures.compactMap { sourceID, reading -> (z: Double, fresh: Double)? in
            guard let robust = baseline.temperature[sourceID] else { return nil }
            let fresh = freshness(age: now.timeIntervalSince(reading.end), maxAge: temperatureMaxAge)
            return (max(0, clamp(robust.z(reading.value, minimumScale: 0.15))), fresh)
        }
        if let strongest = thermal.max(by: { $0.z * $0.fresh < $1.z * $1.fresh }), strongest.fresh > 0 {
            components.append(Component(signal: .thermalStrain, z: strongest.z, weight: Signal.thermalStrain.weight * strongest.fresh))
        }

        // 5. SpO2: a fall only.
        if let robust = baseline.spo2,
           let reading = recent(.spo2, spo2MaxAge).filter({ $0.provenance != .estimated }).max(by: { $0.end < $1.end }) {
            let fresh = freshness(age: now.timeIntervalSince(reading.end), maxAge: spo2MaxAge)
            components.append(Component(
                signal: .oxygenation,
                z: max(0, clamp(-robust.z(reading.value, minimumScale: 0.8))),
                weight: Signal.oxygenation.weight * fresh
            ))
        }

        components.removeAll { $0.weight <= 0 }
        let hasAnchor = components.contains { $0.signal == .vagalWithdrawal || $0.signal == .heartRateElevation }
        guard heartRate != nil || hrvFreshness > 0 else { return .failure(.noCurrentSignal) }
        let evidence = components.reduce(0) { $0 + $1.weight }
        guard hasAnchor, evidence >= minimumEvidence else { return .failure(.insufficientEvidence) }

        let composite = components.reduce(0) { $0 + $1.weight * $1.z } / evidence
        let fullEvidence = Signal.allCases.reduce(0) { $0 + $1.weight }
        let confidence = min(1, evidence / fullEvidence)
        // Thin evidence is pulled towards the typical score rather than trusted in full.
        var score = typicalScore + (logistic(composite) - typicalScore) * confidence.squareRoot()
        if let previous, now.timeIntervalSince(previous.at) >= 0, now.timeIntervalSince(previous.at) <= smoothingHorizon {
            score = (1 - smoothingWeight) * score + smoothingWeight * previous.score
        }
        score = min(100, max(0, score))

        return .success(Assessment(
            score: score,
            band: Band(score: score),
            components: components,
            confidence: confidence,
            heartRate: heartRate,
            assessedAt: now
        ))
    }

    static func clamp(_ z: Double) -> Double { min(3, max(-3, z)) }

    static func localHour(of date: Date, utcOffset: Int) -> Int {
        let seconds = (Int(date.timeIntervalSince1970) + utcOffset) % 86_400
        return ((seconds + 86_400) % 86_400) / 3_600
    }

    /// Shown wherever the stress index appears. Localized: a caveat the reader cannot read
    /// is not a caveat, and every clause must survive translation.
    static let disclaimer = String(
        localized: "estimate.stress.disclaimer",
        defaultValue: """
            Stress is HeartSync's estimate, not a measurement: your HRV and heart rate compared \
            with your own recent baseline for this time of day, with breathing, temperature, and \
            blood oxygen when they are available. Exercise, caffeine, illness, and poor sensor \
            contact move it too. It is not a medical assessment.
            """,
        comment: "Disclaimer shown with the estimated stress index. Keep every clause: an estimate, relative to the user's own baseline, other causes move it, not medical."
    )
}

extension StressModel {
    /// Why no stress level is shown, in words a user can act on.
    static func explanation(_ reason: Unavailable) -> String {
        switch reason {
        case .noCurrentSignal:
            "No stress level: no heart rate or HRV from the last few minutes."
        case .likelyExercise(let heartRate):
            "No stress level: a heart rate of \(MetricKind.heartRate.formatWithUnit(heartRate)) looks like exercise, which HeartSync does not read as stress."
        case .insufficientEvidence:
            "No stress level yet: HeartSync needs a few days of your own HRV and heart-rate history to compare with."
        }
    }
}
