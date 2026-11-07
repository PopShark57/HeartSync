import Foundation

/// How often a screen may re-read history while readings keep arriving.
///
/// A Bluetooth strap ingests one reading a second, and every reading bumps the store's
/// change token. A screen that keys its load on that token re-reads and re-windows its whole
/// range after every reading — for a 30-day chart, on the main actor, once a second. This
/// separates the two reasons a load can start:
///
/// - **The user changed the question** (range, session, estimate toggle, sources, retry).
///   That loads at once; a lagging answer to a new question would describe the old one.
/// - **Only new data arrived.** That is coalesced to at most one reload per
///   `minimumInterval`, and the screen says how old its result is while it lags.
///
/// Displayed values and verdicts are unchanged by this: each load is the same computation
/// over the same range, just run less often.
enum LiveReloadPolicy {

    /// The debounce every load waits, so dragging across a range picker starts one load
    /// rather than one per intermediate selection.
    static let debounce: TimeInterval = 0.016

    /// The live Now screen: its rows are "now", so it keeps up at one reload a second.
    static let liveScreenInterval: TimeInterval = 1

    /// Reloads allowed per chart bucket while only new data arrives.
    static let reloadsPerChartBucket: Double = 30

    /// How new history reaches the screens of this app.
    enum Arrival: Sendable {
        /// Collected here, as often as a reading a second (the iPhone).
        case live
        /// Copied from the iPhone in bursts, each published once (`MacMirrorPublicationGate`):
        /// the Mac mirror.
        case mirrored
    }

    /// The longest a Mac screen waits to re-read once a sync has landed.
    ///
    /// A mirror changes only when a sync burst is published, at most every couple of seconds
    /// even while a strap streams on the phone. The phone's spacing kept a month comparison
    /// on the Mac twelve minutes behind a sync that had already finished, which read as the
    /// sync not working. A Mac re-reading a month every few seconds, off the main actor, does
    /// not compete with collection the way the phone would.
    static let mirroredMaximumInterval: TimeInterval = 5

    /// Minimum spacing between data-only reloads of a history screen: a thirtieth of the
    /// chart bucket, never under two seconds. That is 2 s at 1H, 10 s at 6H, 30 s at 24H,
    /// 2 min at 7D, and 12 min at 30D, and never over `mirroredMaximumInterval` on the Mac.
    ///
    /// A reload re-reads the whole range, so its cost grows with the range; spacing grows
    /// with it, which keeps the share of main-thread time roughly constant however long the
    /// range is. A new reading moves only the newest bucket, which is still filling, so a
    /// month chart of six-hour medians loses nothing by refreshing every few minutes — and
    /// the screen says how old its result is meanwhile.
    static func minimumInterval(for period: ComparisonPeriod, arrival: Arrival = .live) -> TimeInterval {
        let spacing = max(2, period.chartBucket / reloadsPerChartBucket)
        switch arrival {
        case .live: return spacing
        case .mirrored: return min(spacing, mirroredMaximumInterval)
        }
    }

    /// Whether a load that has just finished may replace what the screen shows.
    ///
    /// - Parameters:
    ///   - stillAsked: the load answers the question the screen asks now. False once range,
    ///     session, sources, or a retry have changed it: the result describes something else.
    ///   - loadedGeneration: the store generation the load read.
    ///   - shownGeneration: the generation behind what the screen shows, when that answers
    ///     the same question; nil when it answers another one or nothing is shown.
    ///
    /// New data alone cancels a load in flight, because the load key holds the store's
    /// generation, yet the result still answers the question on screen and is the newest
    /// answer there is. Dropping it starved the screen: whenever data changed faster than a
    /// load took (a Mac receiving a sync, a phone with a 1 Hz strap and a month range), no
    /// load ever finished in time and the screen never moved. The newer data follows in the
    /// next coalesced load. A result older than the one shown is still dropped.
    static func accepts(stillAsked: Bool, loadedGeneration: Int, shownGeneration: Int?) -> Bool {
        guard stillAsked else { return false }
        guard let shownGeneration else { return true }
        return loadedGeneration >= shownGeneration
    }

    /// How long a load should wait before running.
    ///
    /// - Parameters:
    ///   - dataOnly: true when nothing but the data generation changed since the last load.
    ///   - elapsed: seconds since the last load completed, or nil when nothing has loaded.
    ///   - minimumInterval: the spacing to keep between data-only reloads.
    static func delay(dataOnly: Bool, elapsed: TimeInterval?, minimumInterval: TimeInterval) -> TimeInterval {
        guard dataOnly, let elapsed else { return debounce }
        return max(debounce, minimumInterval - max(0, elapsed))
    }
}
