#if DEBUG
import SwiftUI

// Xcode previews for every chart view and every Oura section (improvement 41).
//
// Each preview draws its view three times: light, dark, and at an accessibility text size,
// so a change is judged in all three at once. Data comes from the same deterministic
// fixtures the UI tests use: `DebugChartGallery` for device history and
// `OuraManager.chartFixtureSnapshot` for Oura documents. Nothing here reads or writes the
// user's store.

/// Light, dark, and large-text copies of one view.
private struct PreviewVariants<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                variant("Light") { content().environment(\.colorScheme, .light) }
                variant("Dark") { content().environment(\.colorScheme, .dark) }
                variant("Accessibility text") { content().environment(\.dynamicTypeSize, .accessibility3) }
            }
            .padding()
        }
    }

    private func variant<Variant: View>(_ title: String, @ViewBuilder _ view: () -> Variant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            view()
                .padding(12)
                .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
private enum PreviewFixtures {
    static let now = Date.now

    static let store: HealthStore = {
        let store = HealthStore(persistenceEnabled: false)
        DebugChartGallery.populate(store: store, estimateSourceID: AppModel.estimateSourceID, now: now)
        return store
    }()

    static func metricDetail(_ kind: MetricKind, range: TimeRange) -> MetricDetailSnapshot {
        MetricDetailSnapshot(store: store, kind: kind, range: range, includeEstimates: true, hrvQuality: [:])
    }

    static func pair(range: TimeRange) -> PairwiseSnapshot {
        PairwiseSnapshot(
            store: store,
            kind: .heartRate,
            sourceA: DebugChartGallery.strapAID,
            sourceB: DebugChartGallery.watchID,
            period: .rolling(range)
        )
    }

    static let pairStyle: PairwiseChartStyle = {
        let a = store.source(id: DebugChartGallery.strapAID)
        let b = store.source(id: DebugChartGallery.watchID)
        return PairwiseChartStyle(
            colorA: a?.color ?? .blue,
            colorB: b?.color ?? .orange,
            symbolA: a?.symbol ?? .circle,
            symbolB: b?.symbol ?? .square
        )
    }()

    static let oura = OuraManager.chartFixtureSnapshot(now: now)
}

// MARK: - Device charts

#Preview("Metric detail, 30 days") {
    @Previewable @State var selected: Date?
    let snapshot = PreviewFixtures.metricDetail(.heartRate, range: .month)
    PreviewVariants {
        MetricDetailChart(
            kind: .heartRate,
            chart: snapshot.chart,
            series: snapshot.series,
            emphasisedSourceID: nil,
            selectedPeriod: nil,
            isSelectingPeriod: false,
            selectedWindowStart: $selected,
            onSelectPeriod: { _ in }
        )
        .heartSyncChartHeight(HeartSyncTheme.Chart.historyHeight)
    }
}

#Preview("Metric detail, estimates") {
    @Previewable @State var selected: Date?
    let snapshot = PreviewFixtures.metricDetail(.vo2Max, range: .month)
    PreviewVariants {
        MetricDetailChart(
            kind: .vo2Max,
            chart: snapshot.chart,
            series: snapshot.series,
            emphasisedSourceID: nil,
            selectedPeriod: nil,
            isSelectingPeriod: false,
            selectedWindowStart: $selected,
            onSelectPeriod: { _ in }
        )
        .heartSyncChartHeight(HeartSyncTheme.Chart.historyHeight)
    }
}

#Preview("Pairwise timeline") {
    @Previewable @State var selected: Date?
    let snapshot = PreviewFixtures.pair(range: .week)
    PreviewVariants {
        PairwiseTimelineChart(
            kind: .heartRate,
            snapshot: snapshot,
            style: PreviewFixtures.pairStyle,
            nameA: "Polar H10 (left)",
            nameB: "Apple Watch",
            selectedObservationStart: $selected,
            step: { _ in }
        )
        .heartSyncChartHeight(HeartSyncTheme.Chart.pairTimelineHeight)
    }
}

#Preview("Bland–Altman") {
    @Previewable @State var selected: Date?
    let snapshot = PreviewFixtures.pair(range: .week)
    PreviewVariants {
        PairwiseDifferenceChart(
            kind: .heartRate,
            snapshot: snapshot,
            selectedObservationStart: $selected,
            step: { _ in }
        )
        .heartSyncChartHeight(HeartSyncTheme.Chart.blandAltmanHeight)
    }
}

// MARK: - Oura sections

#Preview("Oura scores") {
    let snapshot = PreviewFixtures.oura
    PreviewVariants {
        OuraScoresSection(
            activity: snapshot.latestActivity,
            readiness: snapshot.latestReadiness,
            sleepScore: snapshot.latestSleepScore,
            resilience: snapshot.latestResilience,
            stress: snapshot.latestStress,
            activityTrend: .activityScore(snapshot.activities),
            readinessTrend: .readinessScore(snapshot.readiness),
            sleepTrend: .sleepScore(snapshot.sleepScores)
        )
    }
}

#Preview("Oura biomarkers") {
    let snapshot = PreviewFixtures.oura
    PreviewVariants {
        OuraBiomarkersSection(
            heartRate: snapshot.latestHeartRate,
            sleep: snapshot.latestSleep,
            readiness: snapshot.latestReadiness,
            oxygen: snapshot.latestOxygen,
            cardiovascularAge: snapshot.latestCardiovascularAge,
            vo2Max: snapshot.latestVO2Max,
            lowestHeartRateTrend: .lowestHeartRate(snapshot.sleeps),
            rmssdTrend: .rmssd(snapshot.sleeps),
            temperatureDeviationTrend: .temperatureDeviation(snapshot.readiness)
        )
    }
}

#Preview("Oura heart rate") {
    PreviewVariants {
        OuraHeartRateSection(heartRates: PreviewFixtures.oura.heartRates)
    }
}

#Preview("Oura sleep stages") {
    PreviewVariants {
        OuraSleepSection(sleep: PreviewFixtures.oura.latestSleep)
    }
}

#Preview("Oura movement") {
    PreviewVariants {
        OuraMovementSection(activity: PreviewFixtures.oura.latestActivity)
    }
}

#Preview("Oura timeline and ring") {
    let snapshot = PreviewFixtures.oura
    PreviewVariants {
        OuraTimelineSection(
            workouts: snapshot.workouts,
            sessions: snapshot.sessions,
            enhancedTags: snapshot.enhancedTags,
            tags: snapshot.tags,
            restModePeriods: snapshot.restModePeriods
        )
        OuraRingSection(battery: snapshot.latestBatteryLevel, ring: snapshot.currentRing)
    }
}
#endif
