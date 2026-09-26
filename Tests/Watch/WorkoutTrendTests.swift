import Foundation
import Testing
@testable import HeartSyncChecker

/// The watch workout's five-minute heart-rate trend (improvement 40).
@Suite("Workout heart-rate trend")
struct WorkoutTrendTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ seconds: Double, _ bpm: Double) -> WorkoutHeartRate {
        WorkoutHeartRate(value: bpm, timestamp: start.addingTimeInterval(seconds))
    }

    @Test("Repeated and out-of-order samples are ignored")
    func deduplicates() {
        var trend = WorkoutHeartRateTrend()
        trend.append(sample(0, 90))
        trend.append(sample(0, 90))
        trend.append(sample(-5, 88))
        trend.append(sample(5, 92))
        #expect(trend.samples.map(\.value) == [90, 92])
    }

    @Test("Only the last five minutes are kept")
    func boundedWindow() {
        var trend = WorkoutHeartRateTrend()
        for second in stride(from: 0.0, through: 600, by: 5) {
            trend.append(sample(second, 100))
        }
        #expect(trend.samples.first?.timestamp == start.addingTimeInterval(300))
        #expect(trend.samples.count <= WorkoutHeartRateTrend.maximumSamples)
        #expect(trend.points(at: start.addingTimeInterval(600)).count == 61)
    }

    @Test("A pause breaks the trend into separate runs")
    func gapsSegment() {
        var trend = WorkoutHeartRateTrend()
        for second in [0.0, 5, 10, 70, 75] { trend.append(sample(second, 110)) }
        #expect(trend.points(at: start.addingTimeInterval(80)).map(\.segment) == [0, 0, 0, 1, 1])
    }

    @Test("Reset forgets everything; nothing is kept between workouts")
    func reset() {
        var trend = WorkoutHeartRateTrend()
        trend.append(sample(0, 90))
        trend.reset()
        #expect(trend.samples.isEmpty)
        #expect(trend.points(at: start).isEmpty)
    }
}
