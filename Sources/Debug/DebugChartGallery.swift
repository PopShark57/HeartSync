#if DEBUG
import Foundation

/// A month of deterministic, in-memory data for judging charts by eye (improvement 41).
///
/// `DebugAnalysisFixtures` proves the evidence flow with a few minutes of two sources. This
/// gallery covers what those minutes cannot show:
///
/// - thirty days, so week and month ranges, their buckets, and zoom have something to draw;
/// - four measuring sources, two of them both called "Polar H10", so disambiguated labels and
///   palette shapes are visible;
/// - gaps of hours and days, so every line visibly breaks;
/// - estimated values beside measured ones;
/// - compacted windows (one stored median per window) older than fourteen days;
/// - the last two hours at one-minute resolution, so Now has trends and a live comparison.
///
/// Values are smooth functions of time, never random, so two runs draw the same pictures.
/// Launch with `--chart-gallery`. Like the other fixtures it installs nothing on disk and
/// starts no transport.
@MainActor
enum DebugChartGallery {
    static let strapAID = "gallery.strap.a"
    static let strapBID = "gallery.strap.b"
    static let watchID = "hk.gallery.watch"
    static let ringID = DataSource.ouraSourceID

    /// - Parameter estimateSourceID: `AppModel.estimateSourceID`, passed in so the fixture
    ///   stays free of the app model and runs in unit tests.
    static func populate(store: HealthStore, estimateSourceID: String, now: Date = .now) {
        guard store.source(id: strapAID) == nil else { return }

        store.upsert(DataSource(id: strapAID, displayName: "Polar H10", transport: .bluetooth, model: "Chest strap, left"))
        store.upsert(DataSource(id: strapBID, displayName: "Polar H10", transport: .bluetooth, model: "Chest strap, right"))
        store.upsert(DataSource(id: watchID, displayName: "Apple Watch", transport: .healthKit, model: "Watch"))
        store.upsert(DataSource(id: ringID, displayName: "Oura Ring", transport: .oura, model: "Oura Cloud"))
        store.upsert(DataSource(
            id: estimateSourceID,
            displayName: "HeartSync Estimate",
            transport: .manual,
            model: "Modelled, not measured"
        ))

        var readings: [Reading] = []
        let day: TimeInterval = 86_400
        let compactionAge = HealthStore.minimumCompactionAge
        let start = ComparisonEngine.floorToWindow(now.addingTimeInterval(-30 * day), size: 900)
        let recent = ComparisonEngine.floorToWindow(now.addingTimeInterval(-2 * 3_600), size: 60)

        // Heart rate every fifteen minutes for a month, with each source's own gaps.
        var stamp = start
        while stamp < recent {
            let age = now.timeIntervalSince(stamp)
            let hour = Calendar.current.component(.hour, from: stamp)
            let base = 64 + 9 * sin(stamp.timeIntervalSince1970 / 21_600) + (hour >= 23 || hour < 6 ? -8 : 0)
            // Strap A: absent for three days in the third week.
            if !(17 * day...20 * day).contains(age) {
                readings.append(heartRate(strapAID, base, stamp, compacted: age > compactionAge))
            }
            // Strap B: worn only in the daytime.
            if (7..<22).contains(hour) {
                readings.append(heartRate(strapBID, base + 2, stamp.addingTimeInterval(20), compacted: age > compactionAge))
            }
            // Watch: charging for two hours every evening.
            if !(19..<21).contains(hour) {
                readings.append(heartRate(watchID, base + 1 + 2 * sin(stamp.timeIntervalSince1970 / 3_000), stamp.addingTimeInterval(40), compacted: age > compactionAge))
            }
            // Ring: missed uploads for a day and a half last week.
            if !(4 * day...5.5 * day).contains(age) {
                readings.append(heartRate(ringID, base - 1.5, stamp.addingTimeInterval(50), compacted: age > compactionAge))
            }
            stamp.addTimeInterval(900)
        }

        // The last two hours at one-minute resolution from three sources, with a gap.
        for minute in 0..<120 {
            let when = recent.addingTimeInterval(Double(minute) * 60)
            guard when < now else { break }
            let value = 72 + 6 * sin(Double(minute) / 9)
            readings.append(heartRate(strapAID, value, when, compacted: false))
            if !(40..<55).contains(minute) {
                readings.append(heartRate(watchID, value + 1.5, when.addingTimeInterval(15), compacted: false))
            }
            readings.append(heartRate(ringID, value - 1, when.addingTimeInterval(30), compacted: false))
            if minute.isMultiple(of: 5) {
                readings.append(reading(strapAID, .hrvRMSSD, 44 + 5 * sin(Double(minute) / 20), when, provenance: .derived))
                readings.append(reading(watchID, .spo2, 97 + (minute.isMultiple(of: 10) ? 0 : -1), when))
                readings.append(reading(strapBID, .spo2, 96, when.addingTimeInterval(10)))
            }
        }

        // Daily values for a month: measured resting heart rate and VO2 max, and estimates.
        for dayIndex in 0..<30 {
            let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(dayIndex) * day))
            let wave = sin(Double(dayIndex) / 4)
            if dayIndex != 9 {
                readings.append(reading(watchID, .restingHeartRate, 55 + 2 * wave, midnight.addingTimeInterval(6 * 3_600)))
            }
            if dayIndex != 3 {
                readings.append(reading(ringID, .restingHeartRate, 53 + 2 * wave, midnight.addingTimeInterval(7 * 3_600)))
            }
            if dayIndex.isMultiple(of: 3) {
                readings.append(reading(watchID, .vo2Max, 44 + wave, midnight.addingTimeInterval(12 * 3_600)))
            }
            readings.append(reading(estimateSourceID, .vo2Max, 46 + wave * 1.5, midnight.addingTimeInterval(12 * 3_600 + 60), provenance: .estimated))
        }

        _ = store.append(contentsOf: readings)
    }

    private static func heartRate(_ sourceID: String, _ value: Double, _ date: Date, compacted: Bool) -> Reading {
        guard compacted else { return reading(sourceID, .heartRate, value, date) }
        // What compaction leaves behind: one median per comparison window, flagged so every
        // chart and export treats it as an aggregate, never as a raw sample.
        let window = MetricKind.heartRate.comparisonWindow
        let windowStart = ComparisonEngine.floorToWindow(date, size: window)
        return Reading(
            id: UUID(stableFrom: "gallery.\(sourceID).heartRate.compacted.\(Int(windowStart.timeIntervalSince1970))"),
            sourceID: sourceID,
            kind: .heartRate,
            value: value.rounded(),
            start: windowStart,
            end: windowStart.addingTimeInterval(window),
            metadata: ReadingMetadata(aggregation: AggregationMetadata(
                originalSampleCount: 60,
                originalStandardDeviation: 2.4
            ))
        )
    }

    private static func reading(
        _ sourceID: String,
        _ kind: MetricKind,
        _ value: Double,
        _ date: Date,
        provenance: Provenance = .measured
    ) -> Reading {
        Reading(
            id: UUID(stableFrom: "gallery.\(sourceID).\(kind.rawValue).\(Int(date.timeIntervalSince1970))"),
            sourceID: sourceID,
            kind: kind,
            value: (value * 10).rounded() / 10,
            start: date,
            provenance: provenance
        )
    }
}
#endif
