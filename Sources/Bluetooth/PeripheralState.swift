import Foundation

/// What `BluetoothManager` holds for one app connection session of one peripheral
/// (improvement 66).
///
/// Everything here is born when discovery starts and dies with the session: a disconnect,
/// a fresh Reconnect, the radio turning off, or Forget. Ending a session replaces this one
/// value, so nothing can be left behind by a teardown that forgot a field. That was the
/// failure mode of the two dozen parallel dictionaries this replaces: `forget` left the
/// session counter behind, and a radio power-off ended sessions without resetting the HRV
/// accumulator, so an R–R series could be joined across the outage.
///
/// Generic over the characteristic type so the transitions can be tested without
/// CoreBluetooth; the manager uses `PeripheralLink<CBCharacteristic>`.
struct PeripheralLink<Characteristic> {
    /// Unique across every peripheral and every session. Delayed work captures it and does
    /// nothing if the link it was scheduled for is no longer the current one.
    let session: Int
    /// Service and subscription progress; nil until services are discovered.
    var discovery: BluetoothDiscoveryState?
    /// Metrics accepted on this link. Late discovery callbacks cannot erase them.
    var observedMetrics: Set<MetricKind> = []
    var cadence = StreamCadence()
    /// The no-data watchdog, re-armed by every accepted value.
    var stallTask: Task<Void, Never>?
    /// The beats behind this link's HRV. A window is only meaningful over one continuous
    /// recording, so it lives and dies with the link.
    var hrv = HRVAccumulator()
    var ring = RingLink<Characteristic>()
    /// Discovery bookkeeping keyed by CoreBluetooth object identity. Per link, so the
    /// identifiers of objects from ended sessions do not accumulate.
    var serviceIDs: [ObjectIdentifier: String] = [:]
    var subscriptionIDs: [ObjectIdentifier: String] = [:]
    var characteristicKeys: [ObjectIdentifier: String] = [:]

    init(session: Int) {
        self.session = session
    }

    /// Cancels the work this link scheduled. Called as it is replaced or removed.
    func cancelScheduledWork() {
        stallTask?.cancel()
        ring.timeoutTask?.cancel()
        ring.batteryTask?.cancel()
    }
}

/// The vendor ring plumbing for one link: its two channels, frame reassembly per channel,
/// the purposes of writes awaiting a response, and the timeout in flight. The protocol
/// state itself is `R11MRingSession`, which the manager publishes separately.
struct RingLink<Characteristic> {
    var characteristics: [R11MRingSession.Channel: Characteristic] = [:]
    private var assemblers: [R11MRingSession.Channel: YCBTFrameAssembler] = [:]
    /// Purposes of writes sent with a response, oldest first.
    private(set) var pendingWrites: [R11MRingSession.Purpose] = []
    var timeoutTask: Task<Void, Never>?
    /// The next idle battery query (`R11MRingSession.refreshBattery`).
    var batteryTask: Task<Void, Never>?

    /// Feeds one notification to its channel's assembler.
    mutating func assemble(_ data: Data, on channel: R11MRingSession.Channel) -> [YCBTFrameAssembler.Output] {
        var assembler = assemblers[channel] ?? YCBTFrameAssembler()
        let outputs = assembler.append(data)
        assemblers[channel] = assembler
        return outputs
    }

    mutating func noteWriteSent(_ purpose: R11MRingSession.Purpose) {
        pendingWrites.append(purpose)
    }

    /// The purpose of the oldest write awaiting its result, if any.
    mutating func takeWriteResult() -> R11MRingSession.Purpose? {
        pendingWrites.isEmpty ? nil : pendingWrites.removeFirst()
    }
}

/// What `BluetoothManager` holds for a peripheral across sessions, until Forget.
struct PeripheralRecord {
    /// Reconnection attempts since the last successful connection.
    var reconnectAttempts = 0
    var reconnectTask: Task<Void, Never>?
    /// An explicit Reconnect waiting for the old link's disconnect callback.
    var awaitingFreshReconnect = false
    var freshReconnectFallback: Task<Void, Never>?
    /// The next discovery inventories every service (a diagnostic session).
    var fullDiscoveryRequested = false
    /// Device Information Service strings, accumulated as they arrive.
    var deviceInformation = DeviceInformation()

    func cancelScheduledWork() {
        reconnectTask?.cancel()
        freshReconnectFallback?.cancel()
    }

    mutating func cancelFreshReconnect() {
        awaitingFreshReconnect = false
        freshReconnectFallback?.cancel()
        freshReconnectFallback = nil
    }

    mutating func cancelPendingReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}

/// Device Information Service strings. They are read separately and in no guaranteed
/// order, so the display string is rebuilt from whatever is known each time one lands.
struct DeviceInformation: Equatable, Sendable {
    var manufacturer: String?
    var model: String?
    var firmware: String?

    /// "Polar H10 (firmware 3.1.1)" — the identity first, the revision parenthesised after
    /// it, and any missing part simply omitted.
    var displayString: String {
        let identity = [manufacturer, model]
            .compactMap { $0 }
            .joined(separator: " ")
        guard let firmware, !firmware.isEmpty else { return identity }
        guard !identity.isEmpty else { return "Firmware \(firmware)" }
        return "\(identity) (firmware \(firmware))"
    }
}
