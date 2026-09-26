import Charts
import SwiftUI

/// Full history of one metric with every source overlaid, plus the pairwise agreement
/// statistics for that metric.
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    let kind: MetricKind
    /// A saved session whose exact span this screen analyses, or nil for a rolling preset.
    let session: ComparisonSession?

    /// Seeded once, in `init`. `onAppear` runs again when a pushed pair view is popped, so
    /// assigning the initial range there reset the user's choice on every Back.
    @State private var range: TimeRange
    /// Presentation only. Estimated values are drawn as dashed lines when this is on; they
    /// are never fed into a comparison verdict either way \u{2014} see `MetricDetailSnapshot`.
    @State private var showEstimates = true
    /// Bumped by the retry button so the load key changes and the query runs again.
    @State private var retryToken = 0
    @State private var snapshot: MetricDetailSnapshot?
    /// The last completed load, so a reload caused only by new data can be coalesced.
    @State private var lastLoadedKey: LoadKey?
    @State private var lastLoadedAt: Date?

    init(kind: MetricKind, initialRange: TimeRange = .day, session: ComparisonSession? = nil) {
        self.kind = kind
        self.session = session
        _range = State(initialValue: initialRange)
    }

    /// The span analysed: a saved session's fixed seconds when one is open, otherwise the
    /// rolling preset. Opening "Morning walk" must not quietly show the last 24 hours.
    private var period: ComparisonPeriod {
        session.map { .fixed($0.interval) } ?? .rolling(range)
    }

    /// Everything the snapshot depends on. An unrelated view update leaves this unchanged
    /// and reuses the resolved snapshot instead of re-reading and re-windowing the range.
    private struct LoadKey: Hashable {
        var generation: Int
        var hrvQualityCount: Int
        var kind: MetricKind
        var period: ComparisonPeriod
        var showEstimates: Bool
        var retryToken: Int

        /// True when `other` asks the same question and only the data may have changed.
        func sameSelection(as other: LoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            aligned.hrvQualityCount = hrvQualityCount
            return aligned == self
        }
    }

    private var loadKey: LoadKey {
        LoadKey(
            generation: model.store.changeToken,
            hrvQualityCount: isHRV ? model.bluetooth.hrvQuality.count : 0,
            kind: kind,
            period: period,
            showEstimates: showEstimates,
            retryToken: retryToken
        )
    }

    var body: some View {
        // Resolved off the render path, once per load key. The chart, the band, the
        // legend, the per-device table, and the pair list are five projections of one
        // windowing pass; computing them separately re-read the whole archive and
        // re-bucketed it for each projection, and `TimeRange.interval` is relative to
        // `.now`, so those passes did not even describe the same span. Building it inside
        // `body` also meant every unrelated update paid for the whole pass again.
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                List {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading \(kind.title.lowercased())\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("metric.loading")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        // Cancels a superseded load and rejects a late one, so a slow month-range result
        // cannot replace a newer hour-range selection.
        .task(id: loadKey) {
            let key = loadKey
            // A changed question loads after one frame; new data alone is coalesced, so a
            // 1 Hz strap does not re-read and re-window a month on every reading.
            let wait = LiveReloadPolicy.delay(
                dataOnly: lastLoadedKey.map { key.sameSelection(as: $0) } ?? false,
                elapsed: lastLoadedAt.map { Date.now.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.minimumInterval(for: period)
            )
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let resolved = MetricDetailSnapshot(
                store: model.store,
                kind: kind,
                period: period,
                includeEstimates: showEstimates,
                hrvQuality: isHRV ? model.bluetooth.hrvQuality : [:]
            )
            guard !Task.isCancelled, key == loadKey else { return }
            snapshot = resolved
            lastLoadedKey = key
            lastLoadedAt = .now
        }
    }

    @ViewBuilder
    private func content(_ snapshot: MetricDetailSnapshot) -> some View {
        List {
            Section {
                // A saved session's span is fixed, so the rolling picker is replaced rather
                // than left to imply a range this screen is not analysing.
                if let session {
                    ComparisonSessionBanner(session: session)
                        .accessibilityIdentifier("metric.session")
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("metric.range")
                }

                if snapshot.generation != model.store.changeToken {
                    SnapshotLagNote(resolvedAt: snapshot.resolvedAt)
                }

                if snapshot.hasEstimatedReadings {
                    Toggle("Show estimated values", isOn: $showEstimates)
                        .font(.subheadline)
                }
            } footer: {
                if snapshot.hasEstimatedReadings {
                    Text("Estimated values are modelled, not measured, and are drawn as dashed lines. This switch changes the chart and the per-device table only: an estimate never contributes to a device agreement statistic, whichever way it is set.")
                }
            }

            Section {
                if let failure = snapshot.queryFailure {
                    // A failed read is not an empty range. Saying "no data" here would be a
                    // claim about the user's history that this screen cannot support.
                    HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                        .accessibilityIdentifier("metric.unavailable")
                } else if snapshot.points.isEmpty {
                    Text("No \(kind.title.lowercased()) data in this range.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    chart(snapshot)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
                    legend(snapshot)
                }
            } header: {
                Text(kind.title)
            } footer: {
                if !snapshot.bandPoints.isEmpty {
                    Text("The shaded band spans the highest and lowest device reading in each \(WindowLabel.length(snapshot.bucketSize)) window, coloured by that window's agreement. A wide band means your devices disagree at that moment. Lines and band break where a device, or a second device to compare with, did not report.")
                }
            }

            if !snapshot.perSourceStats.isEmpty {
                Section {
                    ForEach(snapshot.perSourceStats) { entry in
                        PerSourceStatsRow(kind: kind, entry: entry)
                    }
                } header: {
                    Text("Per device, \(periodPhrase(snapshot.period))")
                } footer: {
                    Text("These summarise one median per device per \(WindowLabel.length(snapshot.bucketSize)) window \u{2014} the same windows the chart draws. They are not raw sample statistics: readings older than the compaction age are stored as one median per window, so the original minimum, maximum and mean no longer exist. Where the original sample count was recorded it is shown separately; where it was not, it is shown as unknown.")
                }
            }

            if !snapshot.pairwiseAnalyses.isEmpty {
                Section {
                    ForEach(snapshot.pairwiseAnalyses) { analysis in
                        NavigationLink {
                            // Carries the session too, so a pair opened from a saved
                            // session analyses — and exports — the session's own span.
                            PairwiseAnalysisView(
                                kind: kind,
                                sourceAID: analysis.sourceA,
                                sourceBID: analysis.sourceB,
                                initialRange: range,
                                session: session
                            )
                        } label: {
                            PairwiseAnalysisRow(analysis: analysis)
                        }
                        .accessibilityIdentifier("metric.pair")
                    }
                } header: {
                    Text("Device pairs")
                } footer: {
                    Text("Every eligible pair is listed, including pairs with no overlap or too few paired windows. Open a pair for its timeline, difference plot, evidence, and export.")
                }
            }

            if isHRV {
                Section {
                    Text("HRV is the metric where devices disagree most. Vendors use different window lengths, different artefact-rejection rules, and different sensors \u{2014} an ECG chest strap and an optical ring are not measuring the same signal. Treat each device's HRV as its own scale and watch its trend, rather than expecting two devices to match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.hrvQuality) { entry in
                        HRVQualityRow(entry: entry)
                    }
                } header: {
                    if !snapshot.hrvQuality.isEmpty {
                        Text("How good is this HRV?")
                    }
                } footer: {
                    if !snapshot.hrvQuality.isEmpty {
                        Text("Beat quality is reported by HeartSync's own HRV calculation from the R\u{2013}R intervals a Bluetooth device sent, and describes that device's latest window only. It is a caveat on the numbers above, not a comparison between devices.")
                    }
                }
            }
        }
    }

    private var isHRV: Bool { kind == .hrvRMSSD || kind == .hrvSDNN }

    // MARK: Chart

    private func chart(_ snapshot: MetricDetailSnapshot) -> some View {
        Chart {
            ForEach(snapshot.bandPoints) { band in
                if band.isIsolated {
                    // One compared window between gaps: an area needs two points, so it is
                    // drawn as a short bar spanning that window's spread.
                    RuleMark(
                        x: .value("Time", band.date),
                        yStart: .value("Low", band.low),
                        yEnd: .value("High", band.high)
                    )
                    .foregroundStyle(band.severity.tint.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                } else {
                    // Keyed per run: the band breaks where nothing was compared and where
                    // the severity changes, since an area series takes a single style.
                    AreaMark(
                        x: .value("Time", band.date),
                        yStart: .value("Low", band.low),
                        yEnd: .value("High", band.high),
                        series: .value("Band", band.seriesKey)
                    )
                    .foregroundStyle(band.severity.tint.opacity(0.16))
                    .interpolationMethod(.monotone)
                }
            }

            // Every mark keys on `sourceID`, never on the display name. Two devices called
            // "Polar H10" are two series; renaming one is a label change, not a data move.
            ForEach(snapshot.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value),
                    // Segment key, not source key: the line breaks across a gap in this
                    // source's data rather than implying continuous measurement.
                    series: .value("Source", point.seriesKey)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: point.isEstimate ? [4, 3] : []))
                .interpolationMethod(.monotone)

                // Dots keep single-sample series visible; LineMark alone draws nothing for one point.
                PointMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .symbol(by: .value("Source", point.sourceID))
                .symbolSize(36)
            }
        }
        .chartForegroundStyleScale(domain: snapshot.styleDomain, range: snapshot.styleRange)
        .chartSymbolScale(domain: snapshot.styleDomain, range: snapshot.symbolRange)
        .chartLegend(.hidden)
        .chartYScale(domain: snapshot.yDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat(snapshot.period.displayRange))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    /// Legend entries come from the same `series` the chart scales use, so a label here can
    /// never name a different device than the line it points at. The symbol is spoken as
    /// well as drawn: a legend that only differs by colour is unusable to a reader who
    /// cannot distinguish the two colours.
    private func legend(_ snapshot: MetricDetailSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendEntries(snapshot) }
            VStack(alignment: .leading, spacing: 5) { legendEntries(snapshot) }
        }
    }

    @ViewBuilder
    private func legendEntries(_ snapshot: MetricDetailSnapshot) -> some View {
        ForEach(snapshot.series) { entry in
            HStack(spacing: 5) {
                // The same shape the chart plots, so the key works without colour.
                SourceSymbolGlyph(symbol: entry.symbol, color: entry.color)
                Text(entry.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.label), \(entry.symbol.accessibilityName) marks")
        }
        Spacer(minLength: 0)
    }

    /// Keyed on the snapshot's period rather than the picker, so a saved session's span is
    /// labelled at the zoom that fits it.
    private func axisFormat(_ displayRange: TimeRange) -> Date.FormatStyle {
        switch displayRange {
        case .hour, .sixHours: .dateTime.hour().minute()
        case .day:             .dateTime.hour()
        case .week, .month:    .dateTime.month(.abbreviated).day()
        }
    }

    /// "last 24 hours", or "saved session" for a fixed span. A formatted date is not
    /// lowercased: that would mangle month names in some languages.
    private func periodPhrase(_ period: ComparisonPeriod) -> String {
        period.rollingRange.map { $0.title.lowercased() } ?? "saved session"
    }
}
