import Foundation

// MARK: - Snapshot types

/// A source paired with its most recent reading, before the row is shaped.
struct LiveReading {
    var source: DataSource
    var reading: Reading
}

/// One device's current reading of one metric.
struct SourceReadingRow: Identifiable {
    var source: DataSource
    var value: Double
    var provenance: Provenance
    var timestamp: Date
    /// Offset from the window consensus, present only when this exact reading sits inside
    /// the aligned window the verdict came from. Nil is not "no difference"; it means the
    /// reading was never compared.
    var deltaFromWindowConsensus: Double?
    /// False for a device's last reading from before `DashboardSnapshot.liveWindow`: shown
    /// with its age so a spot measurement does not vanish, never compared.
    var isCurrent: Bool = true

    var id: String { source.id }
}

/// The agreement verdict for one metric, drawn from a single epoch-aligned window.
struct WindowComparison {
    var severity: DiscrepancySeverity
    var spread: Double
    var sourceCount: Int
    var windowSize: TimeInterval
}

/// Everything one card draws, resolved before the card is built.
struct MetricSummary: Identifiable {
    var kind: MetricKind
    var rows: [SourceReadingRow]
    /// Window consensus when the devices were comparable, otherwise the most recent single
    /// reading. Never a mean of values taken minutes apart.
    var headline: Double?
    /// Non-nil only when two or more measured sources shared the current (or immediately
    /// preceding) aligned window.
    var comparison: WindowComparison?
    /// Why no verdict is shown, when more than one source reported but they were not
    /// comparable. Mutually exclusive with `comparison`.
    var notComparedDetail: String?
    /// Trend of the sources on this card. Nil when no source has two windows to join.
    var sparkline: Sparkline? = nil

    var id: MetricKind { kind }

    /// True when at least one device reported inside the live window. A card without a
    /// current row shows the last value each device reported, labelled with its age.
    var isCurrent: Bool { rows.contains(where: \.isCurrent) }

    /// When the newest value on the card was measured.
    var newestTimestamp: Date? { rows.map(\.timestamp).max() }
}

// MARK: - Sparkline

/// A small, axis-free trend for one Now card: one line per source, drawn from the median of
/// each completed comparison window and broken wherever a window is missing.
///
/// It stops at the start of the current window. A window still filling is not a result yet,
/// and stopping there lets the sparkline be read once per window instead of once per
/// reading, which keeps the 1 Hz reload of the Now screen bounded (item 29).
struct Sparkline: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var date: Date
        var value: Double
    }

    struct Series: Identifiable, Equatable, Sendable {
        var sourceID: String
        var points: [Point]
        /// Gap segment of each point; see `ChartSegmentation`.
        var segments: [Int]

        var id: String { sourceID }
        /// Points a line cannot reach, drawn as dots so a lone window is still visible.
        var isolated: Set<Int> { ChartSegmentation.isolatedPositions(segments) }
    }

    var kind: MetricKind
    var series: [Series]
    /// The pinned x domain: the whole span, so a quiet stretch stays visibly empty.
    var start: Date
    var through: Date

    /// The last hour for fast metrics, the last fourteen days for daily ones.
    static func span(for kind: MetricKind) -> TimeInterval {
        kind.comparisonWindow < 3_600 ? 3_600 : 14 * 86_400
    }

    /// Plain-language span for the spoken summary.
    static func spanTitle(for kind: MetricKind) -> String {
        span(for: kind) <= 3_600 ? "the last hour" : "the last 14 days"
    }

    /// Builds the trend for `sourceIDs`, in that order, from readings of `kind`.
    ///
    /// Returns nil when no source has at least two windows: a single point is not a trend.
    static func build(
        kind: MetricKind,
        readings: [Reading],
        sourceIDs: [String],
        through: Date
    ) -> Sparkline? {
        let window = kind.comparisonWindow
        let start = through.addingTimeInterval(-span(for: kind))
        let wanted = Set(sourceIDs)
        var buckets: [String: [Date: [Double]]] = [:]
        for reading in readings where reading.kind == kind && wanted.contains(reading.sourceID) {
            let bucket = ComparisonEngine.floorToWindow(reading.midpoint, size: window)
            guard bucket >= start, bucket < through else { continue }
            buckets[reading.sourceID, default: [:]][bucket, default: []].append(reading.value)
        }
        let series = sourceIDs.compactMap { sourceID -> Series? in
            guard let byBucket = buckets[sourceID], !byBucket.isEmpty else { return nil }
            let points = byBucket.keys.sorted().map { bucket in
                Point(date: bucket, value: ComparisonEngine.median(byBucket[bucket] ?? []))
            }
            let segments = ChartSegmentation.segments(
                for: points.map(\.date),
                threshold: ChartSegmentation.windowThreshold(windowSize: window)
            )
            return Series(sourceID: sourceID, points: points, segments: segments)
        }
        guard series.contains(where: { $0.points.count >= 2 }) else { return nil }
        return Sparkline(kind: kind, series: series, start: start, through: through)
    }

    /// One sentence per source for VoiceOver: first and last window, and the range.
    func spokenSummary(names: [String: String]) -> String {
        let parts = series.map { series -> String in
            let name = names[series.sourceID] ?? series.sourceID
            guard let first = series.points.first, let last = series.points.last else { return name }
            let values = series.points.map(\.value)
            let low = values.min() ?? first.value
            let high = values.max() ?? first.value
            let gaps = Set(series.segments).count - 1
            var text = "\(name): \(kind.formatWithUnit(first.value)) to \(kind.formatWithUnit(last.value)), range \(kind.format(low)) to \(kind.formatWithUnit(high))"
            if gaps > 0 {
                text += ", " + String(
                    localized: "dashboard.spoken.gaps",
                    defaultValue: "\(gaps) gaps",
                    comment: "Spoken description of a trend line. The argument is how many gaps it has."
                )
            }
            return text
        }
        return "Trend over \(Self.spanTitle(for: kind)). " + parts.joined(separator: ". ")
    }
}

/// A cached trend, reused until the next comparison window closes or the sources change.
/// Caches "no trend" too, so a metric without one is not re-read every second.
struct SparklineCacheEntry: Sendable {
    var through: Date
    var sourceIDs: [String]
    var sparkline: Sparkline?
}

// MARK: - Source status

/// What a source chip on Now may claim.
///
/// Only a transport that streams (`SourceTransport.isLive`, today Bluetooth) can be Live,
/// and only while its connection is actually streaming. Apple Health and Oura are pulled,
/// so the most they can say is when they last synced.
enum SourceChipStatus: Equatable, Sendable {
    case live
    case synced(Date)
    case waiting

    static func resolve(transport: SourceTransport, isStreaming: Bool, lastSyncedAt: Date?) -> Self {
        if transport.isLive {
            return isStreaming ? .live : .waiting
        }
        return lastSyncedAt.map(Self.synced) ?? .waiting
    }

    func title(relativeTo now: Date) -> String {
        switch self {
        case .live:
            "Live"
        case .synced(let date):
            now.timeIntervalSince(date) < 60
                ? "Synced just now"
                : "Synced \(WindowLabel.elapsed(now.timeIntervalSince(date))) ago"
        case .waiting:
            "Waiting"
        }
    }
}

// MARK: - Snapshot

/// One resolved pass over the store for the live screen.
///
/// Building every card from a single bounded read keeps the screen O(recent readings)
/// instead of O(archive × metrics × cards), and makes every card describe the same instant.
///
/// The read is bounded per metric. It used to be two days of every metric — twice the
/// longest comparison window — re-read on every Bluetooth reading, so one 1 Hz strap made
/// this screen decode up to two days of rows once a second. A card needs far less: its rows
/// are the last `liveWindow`, and its verdict looks at the current and the previous aligned
/// window only. Displayed values and verdicts are unchanged; see `lookback(for:)`.
struct DashboardSnapshot {
    let metrics: [MetricSummary]
    /// Trends by metric, handed to the next snapshot so a trend is re-read only when its
    /// window closes.
    let sparklineCache: [MetricKind: SparklineCacheEntry]
    /// Set when a history read failed. The cards are then missing for want of data, and the
    /// screen must say so rather than showing "waiting for data".
    let queryFailure: HealthStoreQueryError?

    /// Readings older than this are not "now" and are dropped from the rows, matching
    /// `ComparisonEngine.latestBySource`'s own default.
    nonisolated static let liveWindow: TimeInterval = 15 * 60

    /// The outer bound the screen has always used: twice the longest comparison window.
    /// Only readings still current by their end are read this far back.
    nonisolated static let outerLookback: TimeInterval =
        2 * (MetricKind.allCases.map(\.comparisonWindow).max() ?? 86_400)

    /// How far back one metric's windows are read: twice its comparison window, plus the
    /// live window, never beyond the two days the screen has always read.
    ///
    /// The verdict can only come from the current or the immediately preceding aligned
    /// window, so two windows cover it; the live window lets the "not compared" note find a
    /// shared window from the last quarter hour. For a 60-second metric that is 17 minutes
    /// instead of two days; a daily metric still reads its two days, which is a handful of
    /// rows through the per-metric index.
    ///
    /// Rows are decided by a reading's *end*, not its midpoint, so a long interval reading
    /// that ended recently — an overnight average — is read separately through the `end`
    /// index rather than by widening this window.
    nonisolated static func lookback(for kind: MetricKind) -> TimeInterval {
        min(outerLookback, 2 * kind.comparisonWindow + liveWindow)
    }

    /// How long a device's last reading stays on Now once nothing newer has arrived.
    ///
    /// Blood pressure, SpO\u{2082}, temperature, and respiratory rate are spot or nightly
    /// measurements. Dropping them after `liveWindow` meant a card existed only in the quarter
    /// hour after a measurement, so Now showed heart rate and little else. Such a reading is
    /// now kept for a week (a month for a daily summary such as VO\u{2082} max), shown with its
    /// age, and never compared: the verdict still comes from the live windows only.
    nonisolated static func recentHorizon(for kind: MetricKind) -> TimeInterval {
        kind.isIntervalSummary ? 30 * 86_400 : 7 * 86_400
    }

    /// Display order of `MetricKind`, precomputed so the comparator is O(1) and total.
    private static let displayOrder: [MetricKind: Int] = Dictionary(
        uniqueKeysWithValues: MetricKind.allCases.enumerated().map { ($0.element, $0.offset) }
    )

    /// - Parameter lookback: per-metric window length; injectable so a test can compare the
    ///   bounded read against the previous two-day read at the same instant.
    @MainActor
    init(
        store: HealthStore,
        now: Date,
        lookback: (MetricKind) -> TimeInterval = DashboardSnapshot.lookback(for:),
        sparklineCache previousCache: [MetricKind: SparklineCacheEntry] = [:]
    ) {
        self.init(history: store.history, now: now, lookback: lookback, sparklineCache: previousCache)
    }

    /// Built from a `HealthHistory`, so Now can build it off the main actor.
    init(
        history store: HealthHistory,
        now: Date,
        lookback: (MetricKind) -> TimeInterval = DashboardSnapshot.lookback(for:),
        sparklineCache previousCache: [MetricKind: SparklineCacheEntry] = [:]
    ) {
        // A minute of forward tolerance so a reading whose timestamp is slightly ahead of
        // the clock is not excluded from its own current window.
        let horizon = now.addingTimeInterval(60)

        // Readings still current by their end, however long ago their midpoint was.
        let live = store.readingsOutcome(
            endingAtOrAfter: now.addingTimeInterval(-Self.liveWindow),
            midpointIn: DateInterval(start: now.addingTimeInterval(-Self.outerLookback), end: horizon)
        )
        var failure = live.error
        let liveByKind = Dictionary(grouping: live.valueOrEmpty, by: \.kind)

        var summaries: [MetricSummary] = []
        var cache: [MetricKind: SparklineCacheEntry] = [:]
        for kind in MetricKind.allCases {
            let windowed = store.readingsOutcome(
                kind: kind,
                in: DateInterval(start: now.addingTimeInterval(-lookback(kind)), end: horizon)
            )
            failure = failure ?? windowed.error
            let readings = Self.union(windowed.valueOrEmpty, liveByKind[kind] ?? [])
            let earlier = Self.earlierReadings(kind: kind, excluding: readings, store: store, now: now, horizon: horizon)
            failure = failure ?? earlier.error
            guard !readings.isEmpty || !earlier.valueOrEmpty.isEmpty,
                  var summary = Self.summary(
                      kind: kind,
                      readings: readings,
                      earlier: earlier.valueOrEmpty,
                      store: store,
                      now: now
                  )
            else { continue }
            let entry = Self.sparklineEntry(
                kind: kind,
                sourceIDs: summary.rows.map(\.source.id),
                store: store,
                now: now,
                previous: previousCache[kind]
            )
            if let entry { cache[kind] = entry }
            summary.sparkline = entry?.sparkline
            summaries.append(summary)
        }

        self.sparklineCache = cache
        self.queryFailure = failure
        self.metrics = summaries.sorted { lhs, rhs in
            if lhs.kind.isContinuous != rhs.kind.isContinuous { return lhs.kind.isContinuous }
            return Self.order(of: lhs.kind) < Self.order(of: rhs.kind)
        }
    }

    /// Reuses the previous trend while its window is still open, otherwise reads the span
    /// once through the per-metric index. A failed read shows no trend and is not cached, so
    /// the next reload tries again; the card's values are unaffected.
    private static func sparklineEntry(
        kind: MetricKind,
        sourceIDs: [String],
        store: HealthHistory,
        now: Date,
        previous: SparklineCacheEntry?
    ) -> SparklineCacheEntry? {
        let through = ComparisonEngine.floorToWindow(now, size: kind.comparisonWindow)
        if let previous, previous.through == through, previous.sourceIDs == sourceIDs {
            return previous
        }
        let outcome = store.readingsOutcome(
            kind: kind,
            in: DateInterval(start: through.addingTimeInterval(-Sparkline.span(for: kind)), end: through)
        )
        guard outcome.error == nil else { return nil }
        return SparklineCacheEntry(
            through: through,
            sourceIDs: sourceIDs,
            sparkline: Sparkline.build(kind: kind, readings: outcome.valueOrEmpty, sourceIDs: sourceIDs, through: through)
        )
    }

    /// Each enabled device's last reading of `kind` within `recentHorizon(for:)`, for the
    /// devices that have nothing current in `readings`. One indexed `LIMIT 1` read per device
    /// that has ever reported the metric.
    private static func earlierReadings(
        kind: MetricKind,
        excluding readings: [Reading],
        store: HealthHistory,
        now: Date,
        horizon: Date
    ) -> HealthStoreQueryOutcome<[Reading]> {
        let current = Set(ComparisonEngine.latestBySource(
            from: readings,
            kind: kind,
            now: now,
            staleAfter: liveWindow
        ).keys)
        let range = DateInterval(start: now.addingTimeInterval(-recentHorizon(for: kind)), end: horizon)
        var found: [Reading] = []
        for source in store.enabledSources
        where source.observedMetrics.contains(kind) && !current.contains(source.id) {
            let outcome = store.latestOutcome(kind: kind, sourceID: source.id, midpointIn: range)
            if let error = outcome.error { return .failure(error) }
            if let reading = outcome.value ?? nil, reading.isPlausible { found.append(reading) }
        }
        return .success(found)
    }

    /// Both reads can return the same reading; each is kept once.
    private static func union(_ first: [Reading], _ second: [Reading]) -> [Reading] {
        guard !second.isEmpty else { return first }
        var seen = Set(first.map(\.id))
        return first + second.filter { seen.insert($0.id).inserted }
    }

    private static func order(of kind: MetricKind) -> Int {
        displayOrder[kind] ?? MetricKind.allCases.count
    }

    /// Builds one card's worth of state, or nil when nothing recent enough exists.
    ///
    /// The verdict comes from `ComparisonEngine.windows` with the metric's own comparison
    /// window and the engine's default exclusion of estimates, which is exactly what the
    /// Compare tab does. Only the current bucket or the one immediately before it can
    /// produce a verdict on a screen called "Now".
    private static func summary(
        kind: MetricKind,
        readings: [Reading],
        earlier: [Reading] = [],
        store: HealthHistory,
        now: Date
    ) -> MetricSummary? {
        let latest = ComparisonEngine.latestBySource(
            from: readings,
            kind: kind,
            now: now,
            staleAfter: liveWindow
        )

        // Sources with something live to show, resolved once so the verdict below can be
        // checked against what the card actually displays.
        let visible = latest.compactMap { sourceID, reading -> LiveReading? in
            guard let source = store.source(id: sourceID) else { return nil }
            return LiveReading(source: source, reading: reading)
        }
        // Devices whose last reading is older than the live window. They are shown, with
        // their age, and take no part in the verdict below.
        let previous = earlier.compactMap { reading -> LiveReading? in
            guard latest[reading.sourceID] == nil, let source = store.source(id: reading.sourceID) else { return nil }
            return LiveReading(source: source, reading: reading)
        }
        guard !visible.isEmpty || !previous.isEmpty else { return nil }
        let visibleIDs = Set(visible.map(\.source.id))

        let windowSize = kind.comparisonWindow
        let windows = ComparisonEngine.windows(from: readings, kind: kind)
        // Shape the window to the rows this card actually displays. A third source can
        // still have data in this bucket but already be stale; allowing its hidden value
        // into the consensus/spread would make the badge describe a different set of
        // devices than the card beneath it.
        let shared = windows.reversed().compactMap { window -> ComparisonWindow? in
            let onScreen = window.values.filter { visibleIDs.contains($0.sourceID) }
            guard onScreen.count >= 2 else { return nil }
            return ComparisonWindow(
                kind: window.kind,
                start: window.start,
                duration: window.duration,
                values: onScreen
            )
        }.first
        let currentBucket = ComparisonEngine.floorToWindow(now, size: windowSize)
        let isCurrent = (shared?.start ?? .distantPast) >= currentBucket.addingTimeInterval(-windowSize)
        let aligned = isCurrent ? shared : nil

        let liveRows = visible
            .map { live in
                SourceReadingRow(
                    source: live.source,
                    value: live.reading.value,
                    provenance: live.reading.provenance,
                    timestamp: live.reading.end,
                    deltaFromWindowConsensus: delta(for: live.reading, in: aligned, kind: kind)
                )
            }
            .sorted { $0.source.displayName < $1.source.displayName }
        let previousRows = previous
            .map { earlier in
                SourceReadingRow(
                    source: earlier.source,
                    value: earlier.reading.value,
                    provenance: earlier.reading.provenance,
                    timestamp: earlier.reading.end,
                    deltaFromWindowConsensus: nil,
                    isCurrent: false
                )
            }
            .sorted { $0.timestamp > $1.timestamp }
        let rows = liveRows + previousRows

        let comparison = aligned.map { window in
            WindowComparison(
                severity: window.severity,
                spread: window.spread,
                sourceCount: window.values.count,
                windowSize: windowSize
            )
        }

        return MetricSummary(
            kind: kind,
            rows: rows,
            headline: aligned?.consensus ?? rows.max { $0.timestamp < $1.timestamp }?.value,
            comparison: comparison,
            notComparedDetail: comparison == nil
                ? notComparedDetail(
                    rows: liveRows,
                    sharedWindow: shared,
                    sharedWindowIsCurrent: isCurrent,
                    kind: kind,
                    now: now
                )
                : nil
        )
    }

    /// The row's offset from the window consensus, or nil when this reading was not part of
    /// the compared window.
    ///
    /// Three conditions, all required: an aligned window exists, this source contributed to
    /// it, and *this* reading falls inside it. A reading from a later or earlier bucket
    /// would be differenced against a consensus it never participated in, which is the
    /// timing artefact the windowing exists to remove. Estimates are excluded because they
    /// never enter a comparison.
    private static func delta(
        for reading: Reading,
        in window: ComparisonWindow?,
        kind: MetricKind
    ) -> Double? {
        guard let window,
              reading.provenance != .estimated,
              let consensus = window.consensus,
              window.value(for: reading.sourceID) != nil,
              ComparisonEngine.floorToWindow(reading.midpoint, size: kind.comparisonWindow) == window.start
        else { return nil }
        return reading.value - consensus
    }

    /// Plain-language reason a card shows values but no verdict.
    ///
    /// Returns nil when only one source reported, because a single device has nothing to
    /// disagree with and the absence of a badge is already the honest answer.
    private static func notComparedDetail(
        rows: [SourceReadingRow],
        sharedWindow: ComparisonWindow?,
        sharedWindowIsCurrent: Bool,
        kind: MetricKind,
        now: Date
    ) -> String? {
        guard rows.count >= 2 else { return nil }
        let length = WindowLabel.length(kind.comparisonWindow)

        let measured = rows.filter { $0.provenance != .estimated }
        guard measured.count >= 2 else {
            return "Only one of these values was measured. Estimated values are never compared with a device."
        }

        if let sharedWindow {
            guard sharedWindowIsCurrent else {
                let age = WindowLabel.elapsed(now.timeIntervalSince(sharedWindow.end))
                return "The last \(length) window these devices shared ended \(age) ago, so there is nothing current to compare."
            }
            return "Fewer than two of the devices in the current \(length) window are still reporting, so no current comparison is shown."
        }

        guard let oldest = measured.map(\.timestamp).min(),
              let newest = measured.map(\.timestamp).max()
        else { return nil }
        let apart = WindowLabel.elapsed(newest.timeIntervalSince(oldest))
        let lastReport = WindowLabel.elapsed(now.timeIntervalSince(oldest))
        return "Readings are up to \(apart) apart \u{2014} one device last reported \(lastReport) ago \u{2014} so no shared \(length) window covers them both."
    }
}
