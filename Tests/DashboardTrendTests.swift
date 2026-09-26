import Foundation
import Testing
@testable import HeartSyncChecker

/// Now-tab sparklines and source chips (improvement 36).
@Suite("Now sparklines and source status")
@MainActor
struct DashboardTrendTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let strap = DataSource(id: "strap", displayName: "Strap", transport: .bluetooth)
    private let watch = DataSource(id: "hk.watch", displayName: "Watch", transport: .healthKit)

    private func reading(_ source: DataSource, value: Double, secondsAgo: Double) -> Reading {
        Reading(sourceID: source.id, kind: .heartRate, value: value, start: now.addingTimeInterval(-secondsAgo))
    }

    @Test("Each source's trend is one median per completed window, in source order")
    func windowMedians() throws {
        let through = ComparisonEngine.floorToWindow(now, size: 60)
        let readings = [
            // Three samples in one window: the median, not the mean or the last value.
            reading(strap, value: 60, secondsAgo: through.distance(to: now) + 170),
            reading(strap, value: 90, secondsAgo: through.distance(to: now) + 160),
            reading(strap, value: 62, secondsAgo: through.distance(to: now) + 150),
            reading(strap, value: 70, secondsAgo: through.distance(to: now) + 90),
            reading(watch, value: 64, secondsAgo: through.distance(to: now) + 100),
            reading(watch, value: 66, secondsAgo: through.distance(to: now) + 30),
            // The current window is still filling and is left out.
            reading(strap, value: 200, secondsAgo: 1),
        ]
        let sparkline = try #require(Sparkline.build(kind: .heartRate, readings: readings, sourceIDs: ["watch-missing", "strap", "hk.watch"], through: through))
        #expect(sparkline.series.map(\.sourceID) == ["strap", "hk.watch"])
        #expect(sparkline.series[0].points.map(\.value) == [62, 70])
        #expect(sparkline.series[1].points.map(\.value) == [64, 66])
        #expect(sparkline.start == through.addingTimeInterval(-3_600))
        #expect(!sparkline.series.flatMap(\.points).contains { $0.value == 200 })
    }

    @Test("A missing window breaks the line; a lone window is a dot")
    func gapsBreakTheLine() throws {
        let through = ComparisonEngine.floorToWindow(now, size: 60)
        let base = through.distance(to: now)
        let readings = [
            reading(strap, value: 60, secondsAgo: base + 600),
            reading(strap, value: 61, secondsAgo: base + 540),
            // Nine missing minutes, then one window alone.
            reading(strap, value: 70, secondsAgo: base + 30),
        ]
        let series = try #require(Sparkline.build(kind: .heartRate, readings: readings, sourceIDs: ["strap"], through: through)?.series.first)
        #expect(series.segments == [0, 0, 1])
        #expect(series.isolated == [2])
    }

    @Test("A single point is not a trend")
    func singlePointOmitted() {
        let through = ComparisonEngine.floorToWindow(now, size: 60)
        let readings = [reading(strap, value: 60, secondsAgo: through.distance(to: now) + 30)]
        #expect(Sparkline.build(kind: .heartRate, readings: readings, sourceIDs: ["strap"], through: through) == nil)
    }

    @Test("Daily metrics trend over fourteen days, fast ones over an hour")
    func spans() {
        #expect(Sparkline.span(for: .heartRate) == 3_600)
        #expect(Sparkline.span(for: .hrvRMSSD) == 3_600)
        #expect(Sparkline.span(for: .restingHeartRate) == 14 * 86_400)
        #expect(Sparkline.span(for: .vo2Max) == 14 * 86_400)
    }

    @Test("The spoken summary names each device, its range, and its gaps")
    func spokenSummary() throws {
        let through = ComparisonEngine.floorToWindow(now, size: 60)
        let base = through.distance(to: now)
        let readings = [
            reading(strap, value: 60, secondsAgo: base + 600),
            reading(strap, value: 61, secondsAgo: base + 540),
            reading(strap, value: 70, secondsAgo: base + 30),
        ]
        let sparkline = try #require(Sparkline.build(kind: .heartRate, readings: readings, sourceIDs: ["strap"], through: through))
        let spoken = sparkline.spokenSummary(names: ["strap": "Strap"])
        #expect(spoken.hasPrefix("Trend over the last hour."))
        #expect(spoken.contains("Strap"))
        #expect(spoken.contains("1 gap"))
    }

    @Test("The snapshot reuses a trend until its window closes")
    func cachedUntilWindowCloses() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(strap)
        for minute in 1...10 {
            _ = store.append(reading(strap, value: 60 + Double(minute), secondsAgo: Double(minute) * 60))
        }
        let first = DashboardSnapshot(store: store, now: now)
        let trend = try #require(first.metrics.first { $0.kind == .heartRate }?.sparkline)
        let cached = try #require(first.sparklineCache[.heartRate])

        // A reading inside the open window changes the card, not the trend.
        _ = store.append(reading(strap, value: 150, secondsAgo: 0))
        let second = DashboardSnapshot(store: store, now: now.addingTimeInterval(1), sparklineCache: first.sparklineCache)
        #expect(second.metrics.first { $0.kind == .heartRate }?.sparkline == trend)
        #expect(second.sparklineCache[.heartRate]?.through == cached.through)

        // The next window re-reads.
        let later = now.addingTimeInterval(120)
        let third = DashboardSnapshot(store: store, now: later, sparklineCache: second.sparklineCache)
        #expect(third.sparklineCache[.heartRate]?.through == ComparisonEngine.floorToWindow(later, size: 60))
    }

    @Test("Only a streaming Bluetooth source is live; Health and Oura at most synced")
    func chipStatus() {
        let synced = now.addingTimeInterval(-300)
        #expect(SourceChipStatus.resolve(transport: .bluetooth, isStreaming: true, lastSyncedAt: nil) == .live)
        #expect(SourceChipStatus.resolve(transport: .bluetooth, isStreaming: false, lastSyncedAt: synced) == .waiting)
        #expect(SourceChipStatus.resolve(transport: .healthKit, isStreaming: true, lastSyncedAt: synced) == .synced(synced))
        #expect(SourceChipStatus.resolve(transport: .oura, isStreaming: true, lastSyncedAt: nil) == .waiting)
        for transport in [SourceTransport.healthKit, .oura, .manual] {
            #expect(SourceChipStatus.resolve(transport: transport, isStreaming: true, lastSyncedAt: synced) != .live)
        }
        #expect(SourceChipStatus.live.title(relativeTo: now) == "Live")
        #expect(SourceChipStatus.synced(now.addingTimeInterval(-10)).title(relativeTo: now) == "Synced just now")
        #expect(SourceChipStatus.synced(synced).title(relativeTo: now) == "Synced 5 min ago")
    }
}

/// The `--chart-gallery` fixture holds what it promises (improvement 41).
@Suite("Chart gallery fixture")
@MainActor
struct ChartGalleryFixtureTests {
    @Test("Four measuring sources, two same-named, with gaps, estimates, and compacted windows")
    func galleryCoverage() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HealthStore(persistenceEnabled: false)
        DebugChartGallery.populate(store: store, estimateSourceID: "heartsync.estimate", now: now)

        let measuring = store.sources.filter { $0.transport != .manual }
        #expect(measuring.count == 4)
        #expect(measuring.filter { $0.displayName == "Polar H10" }.count == 2)

        let all = store.readingsOutcome(in: DateInterval(start: now.addingTimeInterval(-31 * 86_400), end: now)).valueOrEmpty
        #expect(all.contains { $0.provenance == .estimated && $0.sourceID == "heartsync.estimate" })
        let compacted = all.filter { $0.metadata?.aggregation != nil }
        #expect(!compacted.isEmpty)
        #expect(compacted.allSatisfy { now.timeIntervalSince($0.end) > HealthStore.minimumCompactionAge - 60 })
        #expect(Set(all.map { Calendar.current.startOfDay(for: $0.start) }).count >= 30)

        // Strap A's three-day absence is a real gap in its heart rate.
        let strapA = all.filter { $0.sourceID == DebugChartGallery.strapAID && $0.kind == .heartRate }
            .map(\.start).sorted()
        let longestGap = zip(strapA.dropFirst(), strapA).map { $0.timeIntervalSince($1) }.max() ?? 0
        #expect(longestGap > 2 * 86_400)

        // Now shows a heart-rate trend and a current comparison.
        let snapshot = DashboardSnapshot(store: store, now: now)
        let heartRate = try #require(snapshot.metrics.first { $0.kind == .heartRate })
        #expect(heartRate.sparkline != nil)
        #expect(heartRate.comparison != nil)
    }
}

