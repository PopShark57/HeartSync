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

    var id: MetricKind { kind }
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
@MainActor
struct DashboardSnapshot {
    let metrics: [MetricSummary]
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

    /// Display order of `MetricKind`, precomputed so the comparator is O(1) and total.
    private static let displayOrder: [MetricKind: Int] = Dictionary(
        uniqueKeysWithValues: MetricKind.allCases.enumerated().map { ($0.element, $0.offset) }
    )

    /// - Parameter lookback: per-metric window length; injectable so a test can compare the
    ///   bounded read against the previous two-day read at the same instant.
    init(
        store: HealthStore,
        now: Date,
        lookback: (MetricKind) -> TimeInterval = DashboardSnapshot.lookback(for:)
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
        for kind in MetricKind.allCases {
            let windowed = store.readingsOutcome(
                kind: kind,
                in: DateInterval(start: now.addingTimeInterval(-lookback(kind)), end: horizon)
            )
            failure = failure ?? windowed.error
            let readings = Self.union(windowed.valueOrEmpty, liveByKind[kind] ?? [])
            guard !readings.isEmpty,
                  let summary = Self.summary(kind: kind, readings: readings, store: store, now: now)
            else { continue }
            summaries.append(summary)
        }

        self.queryFailure = failure
        self.metrics = summaries.sorted { lhs, rhs in
            if lhs.kind.isContinuous != rhs.kind.isContinuous { return lhs.kind.isContinuous }
            return Self.order(of: lhs.kind) < Self.order(of: rhs.kind)
        }
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
        store: HealthStore,
        now: Date
    ) -> MetricSummary? {
        let latest = ComparisonEngine.latestBySource(
            from: readings,
            kind: kind,
            now: now,
            staleAfter: liveWindow
        )
        guard !latest.isEmpty else { return nil }

        // Sources with something live to show, resolved once so the verdict below can be
        // checked against what the card actually displays.
        let visible = latest.compactMap { sourceID, reading -> LiveReading? in
            guard let source = store.source(id: sourceID) else { return nil }
            return LiveReading(source: source, reading: reading)
        }
        guard !visible.isEmpty else { return nil }
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

        let rows = visible
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
                    rows: rows,
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
