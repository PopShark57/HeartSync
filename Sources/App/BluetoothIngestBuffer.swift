import Foundation

/// Holds live Bluetooth values for a moment so they commit as one transaction.
///
/// Every accepted value used to be its own `BEGIN IMMEDIATE … COMMIT`, fsynced, at up to
/// 2 Hz per metric per sensor: an overnight strap session was tens of thousands of
/// transactions. Values now wait up to `flushInterval` and commit together. `AppModel`
/// flushes on a timer, when the buffer fills, when a link ends, before a reset, and when
/// the app moves to the background, so a value is never held longer than that and never
/// left behind when the process may be suspended.
///
/// The cost is latency: a live value reaches the store, and so the screens that read it,
/// up to `flushInterval` later. The Now screen already reloads at most once a second.
struct BluetoothIngestBuffer {
    /// Longest a value waits before its batch commits.
    static let flushInterval: TimeInterval = 2
    /// A batch commits as soon as it holds this many values, whatever their age. Bounds
    /// memory if the timer is late, and a burst (a ring's history is not buffered at all).
    static let maximumPending = 240

    private(set) var pending: [Reading] = []
    /// When the oldest pending value arrived.
    private(set) var oldestArrival: Date?

    var isEmpty: Bool { pending.isEmpty }

    /// Adds a value. Returns true when the batch should commit now.
    mutating func append(_ reading: Reading, at now: Date) -> Bool {
        if pending.isEmpty { oldestArrival = now }
        pending.append(reading)
        return isDue(at: now)
    }

    func isDue(at now: Date) -> Bool {
        guard let oldestArrival else { return false }
        return pending.count >= Self.maximumPending
            || now.timeIntervalSince(oldestArrival) >= Self.flushInterval
    }

    /// Everything pending, oldest first, leaving the buffer empty.
    mutating func drain() -> [Reading] {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        oldestArrival = nil
        return batch
    }
}
