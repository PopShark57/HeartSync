@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OSLog

/// A peripheral seen during a scan but not yet added.
struct DiscoveredPeripheral: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var isConnectable: Bool
    var lastSeen: Date

    /// Rough signal quality for the scan list. RSSI is not distance, but it does tell the
    /// user which of two identically-named rings is the one on their hand.
    var signalBars: Int {
        switch rssi {
        case ..<(-90): 0
        case ..<(-75): 1
        case ..<(-60): 2
        default:       3
        }
    }
}

/// Connection lifecycle for one added Bluetooth device.
enum PeripheralConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case linkConnected
    case discoveringServices
    case enablingNotifications(Set<MetricKind>)
    /// Subscribed for these metrics, but no valid measurement has arrived yet.
    case ready(Set<MetricKind>, warning: String?)
    /// Connected and receiving. The associated set is the metrics actually observed.
    case streaming(Set<MetricKind>)
    case unsupported(String)
    case subscriptionFailed(String)
    case streamStalled(Set<MetricKind>, String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .linkConnected, .discoveringServices, .enablingNotifications,
             .ready, .streaming, .streamStalled: true
        case .disconnected, .unsupported, .subscriptionFailed, .failed: false
        }
    }

    /// Connection status for the device row.
    ///
    /// `.failed` carries a reason produced elsewhere (CoreBluetooth error text or an
    /// already-localized message), so it is passed through rather than looked up here.
    /// The streaming case is split by count instead of interpolating a plural suffix,
    /// because a suffix is not how most languages form a plural.
    var title: String {
        switch self {
        case .disconnected:
            String(localized: "peripheral.state.disconnected", defaultValue: "Not connected", comment: "Bluetooth device status: no connection")
        case .connecting:
            String(localized: "peripheral.state.connecting", defaultValue: "Connecting\u{2026}", comment: "Bluetooth device status: connection in progress")
        case .linkConnected:
            String(localized: "peripheral.state.linkConnected", defaultValue: "Connected; checking services\u{2026}", comment: "Bluetooth device status: BLE link connected but health capability has not been verified")
        case .discoveringServices:
            String(localized: "peripheral.state.discoveringServices", defaultValue: "Reading services\u{2026}", comment: "Bluetooth device status: discovering GATT services after connecting")
        case .enablingNotifications(let kinds):
            "Enabling \(kinds.count) metric\(kinds.count == 1 ? "" : "s")\u{2026}"
        case .ready(let kinds, let warning):
            warning ?? "Ready for \(kinds.count) metric\(kinds.count == 1 ? "" : "s"); waiting for data\u{2026}"
        case .streaming(let kinds):
            if kinds.isEmpty {
                String(localized: "peripheral.state.connected", defaultValue: "Connected", comment: "Bluetooth device status: connected but not yet receiving any metric")
            } else if kinds.count == 1 {
                String(localized: "peripheral.state.streaming.one", defaultValue: "Streaming 1 metric", comment: "Bluetooth device status: receiving exactly one metric")
            } else {
                String(localized: "peripheral.state.streaming.many", defaultValue: "Streaming \(kinds.count) metrics", comment: "Bluetooth device status: receiving several metrics. The number is always 2 or more.")
            }
        case .unsupported(let reason), .subscriptionFailed(let reason):
            reason
        case .streamStalled(_, let reason):
            reason
        case .failed(let reason):
            reason
        }
    }

    /// Pure stream transitions keep value, timeout, and recovery behavior executable in
    /// tests without manufacturing CoreBluetooth framework objects.
    func receiving(_ metric: MetricKind) -> Self {
        var observed: Set<MetricKind>
        if case .streaming(let existing) = self {
            observed = existing
        } else {
            observed = []
        }
        observed.insert(metric)
        return .streaming(observed)
    }

    func stalled(_ reason: String) -> Self {
        let relevant: Set<MetricKind>
        switch self {
        case .enablingNotifications(let metrics), .ready(let metrics, _),
             .streaming(let metrics), .streamStalled(let metrics, _):
            relevant = metrics
        default:
            relevant = []
        }
        return .streamStalled(relevant, reason)
    }
}

/// Owns every Bluetooth connection and turns GATT notifications into `Reading`s.
///
/// Main-actor isolated: the `CBCentralManager` is created with a nil queue, which means
/// CoreBluetooth delivers all callbacks on the main queue, so the `assumeIsolated` hops in
/// the delegate methods below are sound rather than hopeful.
@MainActor
@Observable
final class BluetoothManager: NSObject {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Bluetooth")

    // MARK: Observable state

    private(set) var state: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredPeripheral] = []
    private(set) var connectionStates: [UUID: PeripheralConnectionState] = [:]
    /// Live per-device HRV buffer progress, so the UI can show "collecting beats" rather
    /// than an empty HRV tile for the first few minutes.
    private(set) var hrvProgress: [UUID: (beats: Int, seconds: TimeInterval)] = [:]
    /// Quality of the most recently emitted HRV window per device.
    ///
    /// Keyed by `CBPeripheral.identifier`, which is the same UUID the source ID is built
    /// from. Replaced on every emission and cleared on disconnect/forget, because this
    /// describes one live window and a stale entry would caveat the wrong data.
    private(set) var hrvQuality: [UUID: HRVQuality] = [:]
    /// Latest PLX quality and perfusion facts, including frames deliberately withheld from
    /// durable history. Devices can explain a low-perfusion or still-calibrating result.
    private(set) var pulseOximeterQuality: [UUID: (quality: PulseOximeterMeasurement.Quality, pulseAmplitudeIndex: Double?)] = [:]

    /// When true the scan reports every peripheral, not just ones advertising a health
    /// service. Many inexpensive rings omit their service UUIDs from the advertisement
    /// packet and only reveal them after connecting, so this is the fallback that makes
    /// them findable.
    var scanForAllDevices = false

    var isPoweredOn: Bool { state == .poweredOn }

    var stateDescription: String {
        switch state {
        case .poweredOn:
            String(localized: "bluetooth.state.poweredOn", defaultValue: "Ready", comment: "Bluetooth radio status: available for scanning")
        case .poweredOff:
            String(localized: "bluetooth.state.poweredOff", defaultValue: "Bluetooth is off. Turn it on in Settings or Control Centre.", comment: "Bluetooth radio status: the user must switch the radio on")
        case .unauthorized:
            String(localized: "bluetooth.state.unauthorized", defaultValue: "HeartSync is not allowed to use Bluetooth. Enable it in Settings \u{203A} HeartSync.", comment: "Bluetooth radio status: permission denied. HeartSync is the app name and is not translated; the arrow separates Settings navigation steps.")
        case .unsupported:
            String(localized: "bluetooth.state.unsupported", defaultValue: "This device does not support Bluetooth Low Energy.", comment: "Bluetooth radio status: hardware cannot do BLE")
        case .resetting:
            String(localized: "bluetooth.state.resetting", defaultValue: "Bluetooth is restarting\u{2026}", comment: "Bluetooth radio status: the system stack is resetting")
        case .unknown:
            String(localized: "bluetooth.state.unknown", defaultValue: "Checking Bluetooth\u{2026}", comment: "Bluetooth radio status: not yet reported by the system")
        @unknown default:
            String(localized: "bluetooth.state.unavailable", defaultValue: "Unavailable", comment: "Bluetooth radio status: a future state this build does not recognise")
        }
    }

    // MARK: Private state

    private var central: CBCentralManager!
    /// Strong references are mandatory: CoreBluetooth does not retain peripherals, and a
    /// released `CBPeripheral` silently stops delivering notifications.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var hrvAccumulators: [UUID: HRVAccumulator] = [:]
    /// Receipt-time admission keeps a chatty peripheral from turning every callback into a
    /// stored row. It is deliberately per source and metric so one device cannot starve another
    /// and a pulse-oximeter's SpO2 stream does not suppress its pulse stream.
    private var readingAdmission = BluetoothReadingAdmission()
    private var pendingModelInfo: [UUID: DeviceInformation] = [:]
    private var discoveryStates: [UUID: BluetoothDiscoveryState] = [:]
    private var serviceDiscoveryIDs: [ObjectIdentifier: String] = [:]
    private var characteristicSubscriptionIDs: [ObjectIdentifier: String] = [:]
    private var streamStallTasks: [UUID: Task<Void, Never>] = [:]
    private var scanTimeoutTask: Task<Void, Never>?

    /// Scan results as they arrive, before publication.
    ///
    /// The scan allows duplicates, so a busy room delivers advertisement packets far
    /// faster than any list needs to change. Packets land here; `publishDiscovered()`
    /// sorts and copies them into the observable `discovered` at `discoveryPublishInterval`
    /// so SwiftUI is invalidated a few times a second instead of a few hundred.
    private var discoveredByID: [UUID: DiscoveredPeripheral] = [:]
    private var hasUnpublishedDiscoveries = false
    private var discoveryPublishTask: Task<Void, Never>?

    /// Publication cadence for scan results. 400 ms (2.5 Hz) is well inside the ~100 ms
    /// at which a list stops looking responsive, and far below the packet rate.
    private static let discoveryPublishInterval: Duration = .milliseconds(400)
    /// A scan list is a setup-time convenience, not a registry of every beacon in the room.
    /// Keeping only the strongest 256 candidates bounds advertisement-controlled memory and
    /// still leaves ample room for a user choosing among nearby health devices.
    static let maximumDiscoveredPerScan = 256

    /// Reconnection attempts since the last successful connection, per peripheral.
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    /// Reconnection backoff. A ring that connects and drops repeatedly would otherwise
    /// spin a tight connect loop forever; these bound it and give the user a state to
    /// retry from instead of an invisible failure.
    private static let firstReconnectDelay: TimeInterval = 1
    private static let maximumReconnectDelay: TimeInterval = 60
    private static let maximumReconnectAttempts = 6

    private weak var store: HealthStore?
    private var onReading: (@MainActor (Reading) -> Void)?

    /// Device Information Service strings, accumulated as the individual characteristics
    /// arrive. They are read separately and in no guaranteed order, so the display string
    /// is rebuilt from whatever is known each time one lands.
    private struct DeviceInformation {
        var manufacturer: String?
        var model: String?
        var firmware: String?

        /// "Polar H10 (firmware 3.1.1)" \u{2014} the identity first, the revision parenthesised
        /// after it, and any missing part simply omitted.
        var displayString: String {
            let identity = [manufacturer, model]
                .compactMap { $0 }
                .joined(separator: " ")
            guard let firmware, !firmware.isEmpty else { return identity }
            guard !identity.isEmpty else { return "Firmware \(firmware)" }
            return "\(identity) (firmware \(firmware))"
        }
    }

    // MARK: Setup

    func configure(store: HealthStore, onReading: @escaping @MainActor (Reading) -> Void) {
        self.store = store
        self.onReading = onReading
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                // Lets iOS relaunch the app into the background to deliver notifications
                // from a still-connected sensor.
                CBCentralManagerOptionRestoreIdentifierKey: "com.heartsync.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    // MARK: Scanning

    func startScan() {
        guard isPoweredOn, !isScanning else { return }
        discovered.removeAll()
        discoveredByID.removeAll()
        // Keep strong references only for configured devices between scans. Otherwise each
        // scan could retain another roomful of never-added peripherals indefinitely.
        let configuredIDs = Set(store?.sources.map(\.id) ?? [])
        peripherals = peripherals.filter { configuredIDs.contains($0.key.uuidString) }
        hasUnpublishedDiscoveries = false
        isScanning = true
        central.scanForPeripherals(
            withServices: scanForAllDevices ? nil : GATT.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        logger.info("Scan started (allDevices=\(self.scanForAllDevices))")

        // Duplicate-allowing scans are power-hungry; stop automatically after a while so a
        // forgotten setup screen does not drain the battery.
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }

        discoveryPublishTask?.cancel()
        discoveryPublishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.discoveryPublishInterval)
                guard !Task.isCancelled else { return }
                // Return rather than keep ticking if the manager has gone: a `self?` call
                // in the loop body would leave the task spinning for nobody.
                guard let self else { return }
                self.publishDiscovered()
            }
        }
    }

    func stopScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        discoveryPublishTask?.cancel()
        discoveryPublishTask = nil
        guard isScanning else { return }
        isScanning = false
        central?.stopScan()
        // Packets can arrive after the last tick, so publish once more: the list the user
        // is left looking at must be the complete one, not whatever the final tick caught.
        publishDiscovered()
        logger.info("Scan stopped")
    }

    /// Copies coalesced scan results into the observable list, strongest signal first.
    ///
    /// Ties break on name so the ordering is stable across ticks \u{2014} dictionary iteration
    /// order is not, and an unstable sort would make equally-strong devices swap places
    /// several times a second.
    private func publishDiscovered() {
        guard hasUnpublishedDiscoveries else { return }
        hasUnpublishedDiscoveries = false
        discovered = discoveredByID.values.sorted {
            $0.rssi == $1.rssi ? $0.name < $1.name : $0.rssi > $1.rssi
        }
    }

    // MARK: Connecting

    /// Adds a discovered peripheral as a permanent source and connects to it.
    func add(_ peripheral: DiscoveredPeripheral) {
        guard let cb = central.retrievePeripherals(withIdentifiers: [peripheral.id]).first
            ?? peripherals[peripheral.id]
        else {
            logger.error("Could not retrieve peripheral \(peripheral.id.uuidString, privacy: .public)")
            return
        }
        peripherals[peripheral.id] = cb
        store?.upsert(DataSource(
            id: peripheral.id.uuidString,
            displayName: peripheral.name,
            transport: .bluetooth,
            lastSeenAt: .now
        ))
        connect(cb)
    }

    /// Reconnects every Bluetooth source already in the store. Called at launch.
    func reconnectKnownDevices() {
        guard isPoweredOn, let store else { return }
        let ids = store.sources
            .filter { $0.transport == .bluetooth && $0.isEnabled }
            .compactMap { UUID(uuidString: $0.id) }
        guard !ids.isEmpty else { return }

        for peripheral in central.retrievePeripherals(withIdentifiers: ids) {
            peripherals[peripheral.identifier] = peripheral
            connect(peripheral)
        }
        logger.info("Reconnecting \(ids.count) known device(s)")
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard peripheral.state != .connected else {
            discoverServices(on: peripheral)
            return
        }
        connectionStates[peripheral.identifier] = .connecting
        peripheral.delegate = self
        central.connect(peripheral, options: [
            // Ask iOS to keep trying if the device wanders out of range, which rings do
            // constantly, and to notify on reconnection.
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: false,
        ])
    }

    func disconnect(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID), let peripheral = peripherals[uuid] else { return }
        central.cancelPeripheralConnection(peripheral)
        connectionStates[uuid] = .disconnected
    }

    /// User-initiated reconnection. Clears the backoff, because an explicit tap is the
    /// signal that whatever was wrong (device off, out of range) has been dealt with.
    func reconnect(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID) else { return }
        cancelPendingReconnect(for: uuid)
        reconnectAttempts[uuid] = nil
        if let peripheral = peripherals[uuid] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripherals[uuid] = peripheral
            connect(peripheral)
        }
    }

    func forget(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID) else { return }
        if let peripheral = peripherals[uuid] {
            central.cancelPeripheralConnection(peripheral)
        }
        cancelPendingReconnect(for: uuid)
        // Everything keyed by this peripheral goes, or a device re-added later inherits
        // the stale HRV window, quality caveat, or half-collected model string of the one
        // the user just removed.
        peripherals[uuid] = nil
        connectionStates[uuid] = nil
        hrvAccumulators[uuid] = nil
        readingAdmission.reset(sourceID: uuid.uuidString)
        hrvProgress[uuid] = nil
        hrvQuality[uuid] = nil
        pulseOximeterQuality[uuid] = nil
        pendingModelInfo[uuid] = nil
        discoveryStates[uuid] = nil
        streamStallTasks[uuid]?.cancel()
        streamStallTasks[uuid] = nil
        reconnectAttempts[uuid] = nil
        // `discoveredByID` is deliberately left alone: a forgotten device should still be
        // offered by an in-flight scan so the user can add it back.
    }

    private func cancelPendingReconnect(for id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    /// Schedules a reconnection attempt after an exponentially growing delay.
    ///
    /// Shared by the disconnect and fail-to-connect paths. Gives up after
    /// `maximumReconnectAttempts` and leaves the device in `.failed`, which is a state the
    /// user can act on from the devices list \u{2014} a silent retry loop is not.
    private func scheduleReconnect(
        _ peripheral: CBPeripheral,
        gaveUpReason: String = "Lost connection. Use Reconnect to try again."
    ) {
        let id = peripheral.identifier
        cancelPendingReconnect(for: id)

        let attempt = (reconnectAttempts[id] ?? 0) + 1
        guard attempt <= Self.maximumReconnectAttempts else {
            // Names the recovery the devices list actually offers ("Reconnect" in the row's
            // menu) rather than leaving a dead end.
            connectionStates[id] = .failed(gaveUpReason)
            logger.info(
                "Gave up reconnecting \(id.uuidString, privacy: .public) after \(Self.maximumReconnectAttempts) attempts"
            )
            return
        }
        reconnectAttempts[id] = attempt

        let delay = min(
            Self.firstReconnectDelay * pow(2, Double(attempt - 1)),
            Self.maximumReconnectDelay
        )
        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.reconnectTasks[id] = nil
            // The radio can go away while we wait. Retrying then would burn an attempt on
            // a call that cannot succeed; `centralManagerDidUpdateState` reconnects every
            // enabled source when power comes back, so nothing is lost by stopping here.
            guard self.isPoweredOn else { return }
            guard let source = self.store?.source(id: id.uuidString), source.isEnabled else { return }
            guard let peripheral = self.peripherals[id] else { return }
            self.connect(peripheral)
        }
    }

    func connectionState(forSource id: String) -> PeripheralConnectionState {
        guard let uuid = UUID(uuidString: id) else { return .disconnected }
        return connectionStates[uuid] ?? .disconnected
    }

    private func discoverServices(on peripheral: CBPeripheral) {
        connectionStates[peripheral.identifier] = .linkConnected
        discoveryStates[peripheral.identifier] = nil
        streamStallTasks[peripheral.identifier]?.cancel()
        streamStallTasks[peripheral.identifier] = nil
        peripheral.delegate = self
        // Pass an explicit list rather than nil: discovering every service on a chatty
        // device costs seconds and yields nothing this app can read.
        peripheral.discoverServices(GATT.discoverServices)
        connectionStates[peripheral.identifier] = .discoveringServices
    }

    // MARK: Ingest

    @discardableResult
    private func emit(
        sourceID: String,
        kind: MetricKind,
        value: Double,
        start: Date,
        end: Date? = nil,
        provenance: Provenance = .measured,
        metadata: ReadingMetadata? = nil,
        receivedAt: Date
    ) -> Bool {
        // Admission happens before constructing a Reading. The callback path therefore has no
        // temporary unbounded Reading queue for a notification burst.
        guard kind.plausibleRange.contains(value) else { return false }
        guard readingAdmission.accept(sourceID: sourceID, kind: kind, receivedAt: receivedAt) else {
            return false
        }
        onReading?(Reading(
            sourceID: sourceID,
            kind: kind,
            value: value,
            start: start,
            end: end,
            provenance: provenance,
            metadata: metadata
        ))
        return true
    }

    private func note(metric: MetricKind, for peripheralID: UUID) {
        streamStallTasks[peripheralID]?.cancel()
        streamStallTasks[peripheralID] = nil
        let state = (connectionStates[peripheralID] ?? .disconnected).receiving(metric)
        connectionStates[peripheralID] = state
        if case .streaming(let observed) = state {
            scheduleStreamStallCheck(for: peripheralID, expectedMetrics: observed)
        }
    }

    private func applyDiscoveryResolution(for peripheralID: UUID) {
        guard let discovery = discoveryStates[peripheralID] else { return }
        switch discovery.resolution {
        case .discovering:
            connectionStates[peripheralID] = .discoveringServices
        case .enabling(let metrics):
            connectionStates[peripheralID] = .enablingNotifications(metrics)
        case .unsupported(let details):
            connectionStates[peripheralID] = .unsupported(
                details.first ?? "Connected, but no supported measurement characteristic was found. Check that the sensor uses a standard Heart Rate, Pulse Oximeter, or Health Thermometer service."
            )
        case .subscriptionFailed(let details):
            connectionStates[peripheralID] = .subscriptionFailed(
                details.first ?? "Connected, but measurement notifications could not be enabled. Move the sensor closer and use Reconnect."
            )
        case .ready(let metrics, let warnings):
            let warning = warnings.isEmpty ? nil : "Ready with a partial service result; waiting for data."
            connectionStates[peripheralID] = .ready(metrics, warning: warning)
            scheduleStreamStallCheck(for: peripheralID, expectedMetrics: metrics)
        }
    }

    private func scheduleStreamStallCheck(for peripheralID: UUID, expectedMetrics: Set<MetricKind>) {
        streamStallTasks[peripheralID]?.cancel()
        streamStallTasks[peripheralID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            let current = self.connectionStates[peripheralID] ?? .disconnected
            guard case .ready = current else {
                guard case .streaming = current else { return }
                self.connectionStates[peripheralID] = current.stalled(
                    "The measurement stream stopped for 30 seconds. Check sensor contact, then use Reconnect."
                )
                return
            }
            self.connectionStates[peripheralID] = .streamStalled(
                expectedMetrics,
                "Connected and subscribed, but no valid measurement arrived. Check sensor contact, then use Reconnect."
            )
        }
    }

    private func subscriptionCandidate(for characteristic: CBCharacteristic) -> BluetoothDiscoveryState.Candidate? {
        let metrics: Set<MetricKind>
        switch characteristic.uuid {
        case GATT.heartRateMeasurement:
            metrics = [.heartRate, .hrvRMSSD, .hrvSDNN]
        case GATT.plxContinuousMeasurement, GATT.plxSpotCheckMeasurement:
            metrics = [.spo2, .heartRate]
        case GATT.temperatureMeasurement, GATT.intermediateTemperature:
            metrics = [.bodyTemperature]
        default:
            return nil
        }
        let id = "\(characteristic.uuid.uuidString)#\(ObjectIdentifier(characteristic).hashValue)"
        characteristicSubscriptionIDs[ObjectIdentifier(characteristic)] = id
        return BluetoothDiscoveryState.Candidate(id: id, metrics: metrics)
    }

    fileprivate func handleHeartRate(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = HeartRateMeasurement(data: data) else {
            logger.debug("Unparseable HR frame, \(data.count) bytes")
            return
        }
        let id = peripheral.identifier
        let sourceID = id.uuidString
        let now = Date.now

        // A sensor that supports contact detection and says it is off-body is reporting
        // noise. Storing it would generate a large, meaningless discrepancy.
        if measurement.isSensorContactDetected == false { return }
        guard readingAdmission.acceptNotification(
            sourceID: sourceID,
            channel: .heartRate,
            receivedAt: now
        ) else { return }

        if emit(
            sourceID: sourceID,
            kind: .heartRate,
            value: Double(measurement.beatsPerMinute),
            start: now,
            provenance: .measured,
            receivedAt: now
        ) {
            note(metric: .heartRate, for: id)
        }

        guard !measurement.rrIntervalsMS.isEmpty else { return }
        var accumulator = hrvAccumulators[id] ?? HRVAccumulator()
        accumulator.add(intervals: measurement.rrIntervalsMS, at: now)
        hrvProgress[id] = (accumulator.bufferedBeats, accumulator.bufferedDuration)

        if let emission = accumulator.emissionIfReady(at: now) {
            let metrics = emission.metrics
            if emit(sourceID: sourceID, kind: .hrvRMSSD, value: metrics.rmssd,
                    start: emission.observationStart, end: emission.observationEnd,
                    provenance: .derived, metadata: emission.readingMetadata, receivedAt: now) {
                note(metric: .hrvRMSSD, for: id)
            }
            if emission.includesSDNN,
               emit(sourceID: sourceID, kind: .hrvSDNN, value: metrics.sdnn,
                    start: emission.observationStart, end: emission.observationEnd,
                    provenance: .derived, metadata: emission.readingMetadata, receivedAt: now) {
                note(metric: .hrvSDNN, for: id)
            }
            // Published alongside, not stored: it qualifies the window that was just
            // emitted rather than being a measurement of its own.
            hrvQuality[id] = HRVQuality(metrics: metrics, measuredAt: now)
        }
        hrvAccumulators[id] = accumulator
    }

    fileprivate func handlePulseOximeter(_ data: Data, from peripheral: CBPeripheral, isSpotCheck: Bool) {
        let parsed = isSpotCheck
            ? PulseOximeterMeasurement.spotCheck(data: data)
            : PulseOximeterMeasurement.continuous(data: data)
        guard let measurement = parsed else { return }
        let quality = measurement.quality(for: isSpotCheck ? .spotCheck : .continuous)
        pulseOximeterQuality[peripheral.identifier] = (quality, measurement.pulseAmplitudeIndex)
        let values = PulseOximeterIngestionPolicy.durableValues(
            from: measurement,
            sampleType: isSpotCheck ? .spotCheck : .continuous
        )
        guard !values.isEmpty else {
            logger.debug("Pulse oximeter reported a non-durable measurement; skipping")
            return
        }

        let id = peripheral.identifier
        let sourceID = id.uuidString
        let receivedAt = Date.now
        guard let timestamp = BluetoothTimestampPolicy.normalized(
            deviceTimestamp: measurement.timestamp,
            receivedAt: receivedAt,
            maximumAge: store?.retention ?? BluetoothTimestampPolicy.defaultMaximumAge
        ) else {
            logger.debug("Rejected pulse-oximeter timestamp outside the accepted receipt window")
            return
        }
        for durableValue in values {
            let admitted = readingAdmission.acceptNotification(
                sourceID: sourceID,
                channel: durableValue.channel,
                receivedAt: receivedAt
            )
            if admitted, emit(sourceID: sourceID, kind: durableValue.kind, value: durableValue.value,
                              start: timestamp, provenance: .measured, metadata: durableValue.metadata,
                              receivedAt: receivedAt) {
                note(metric: durableValue.kind, for: id)
            }
        }
    }

    fileprivate func handleTemperature(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = TemperatureMeasurement(data: data) else { return }
        let receivedAt = Date.now
        guard let timestamp = BluetoothTimestampPolicy.normalized(
            deviceTimestamp: measurement.timestamp,
            receivedAt: receivedAt,
            maximumAge: store?.retention ?? BluetoothTimestampPolicy.defaultMaximumAge
        ) else {
            logger.debug("Rejected thermometer timestamp outside the accepted receipt window")
            return
        }
        let sourceID = peripheral.identifier.uuidString
        guard readingAdmission.acceptNotification(
            sourceID: sourceID,
            channel: .temperature,
            receivedAt: receivedAt
        ) else { return }
        if emit(sourceID: sourceID, kind: .bodyTemperature, value: measurement.celsius,
                start: timestamp, provenance: .measured, receivedAt: receivedAt) {
            note(metric: .bodyTemperature, for: peripheral.identifier)
        }
    }

    fileprivate func handleBattery(_ data: Data, from peripheral: CBPeripheral) {
        var reader = BinaryReader(data)
        guard let percent = reader.uint8(), percent <= 100 else { return }
        guard readingAdmission.acceptBattery(
            sourceID: peripheral.identifier.uuidString,
            receivedAt: .now
        ) else { return }
        store?.updateBattery(Int(percent), forSource: peripheral.identifier.uuidString)
    }

    /// Records where on the body the sensor sits (Body Sensor Location, 0x2A38).
    ///
    /// A single uint8 from the SIG enumeration. Unknown values are dropped rather than
    /// coerced to `.other`; reported placement is useful evidence, but it neither identifies
    /// sensing technology nor proves why two devices disagree.
    fileprivate func handleBodySensorLocation(_ data: Data, from peripheral: CBPeripheral) {
        var reader = BinaryReader(data)
        guard let raw = reader.uint8(), let location = BodySensorLocation(rawValue: raw) else {
            logger.debug("Unrecognised body sensor location value")
            return
        }
        store?.setBodyLocation(location, forSource: peripheral.identifier.uuidString)
    }

    fileprivate func handleDeviceInfo(_ characteristic: CBCharacteristic, from peripheral: CBPeripheral) {
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        let id = peripheral.identifier
        var info = pendingModelInfo[id] ?? DeviceInformation()
        switch characteristic.uuid {
        case GATT.manufacturerNameString:   info.manufacturer = text
        case GATT.modelNumberString:        info.model = text
        // Firmware matters here because two units of the same model on different firmware
        // are genuinely different measuring instruments, and this app exists to explain
        // why two devices disagree.
        case GATT.firmwareRevisionString:   info.firmware = text
        default: return
        }
        pendingModelInfo[id] = info

        let combined = info.displayString
        guard !combined.isEmpty, let store, var source = store.source(id: id.uuidString) else { return }
        source.model = combined
        store.upsert(source)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        MainActor.assumeIsolated {
            self.state = newState
            if newState == .poweredOn {
                self.reconnectKnownDevices()
            } else {
                // Ends the scan properly rather than only flipping the flag: the timeout
                // and coalescing tasks have to stop too, and the last packets published.
                self.stopScan()
                // Pending reconnects cannot succeed without a radio, and would otherwise
                // spend their attempt ceiling while Bluetooth is off.
                for task in self.reconnectTasks.values { task.cancel() }
                self.reconnectTasks.removeAll()
                // Mark everything disconnected so the UI does not keep showing stale
                // "streaming" badges after the radio goes away.
                for key in self.connectionStates.keys {
                    self.connectionStates[key] = .disconnected
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unnamed device"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { GATT.title(for: $0) }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            // RSSI of 127 is CoreBluetooth's "not available" sentinel, not a strong signal.
            let entry = DiscoveredPeripheral(
                id: id,
                name: name,
                rssi: rssi == 127 ? -100 : rssi,
                advertisedServices: services,
                isConnectable: connectable,
                lastSeen: .now
            )
            if self.discoveredByID[id] == nil,
               self.discoveredByID.count >= Self.maximumDiscoveredPerScan {
                guard let weakest = self.discoveredByID.values.min(by: {
                    $0.rssi == $1.rssi ? $0.lastSeen < $1.lastSeen : $0.rssi < $1.rssi
                }) else { return }
                let outranksWeakest = entry.rssi > weakest.rssi
                    || (entry.rssi == weakest.rssi && entry.lastSeen > weakest.lastSeen)
                guard outranksWeakest else { return }
                self.discoveredByID[weakest.id] = nil
                if self.store?.source(id: weakest.id.uuidString) == nil {
                    self.peripherals[weakest.id] = nil
                }
            }
            self.peripherals[id] = peripheral
            // Coalesced rather than published here: with duplicates allowed this runs for
            // every advertisement packet from every device in range.
            self.discoveredByID[id] = entry
            self.hasUnpublishedDiscoveries = true
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.logger.info("Connected to \(peripheral.identifier.uuidString, privacy: .public)")
            // A connection that actually succeeded resets the backoff, so a device that
            // drops once an hour never accumulates its way to the attempt ceiling.
            self.cancelPendingReconnect(for: peripheral.identifier)
            self.reconnectAttempts[peripheral.identifier] = nil
            self.store?.markSeen(sourceID: peripheral.identifier.uuidString)
            self.discoverServices(on: peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let reason = error?.localizedDescription ?? "Could not connect"
        MainActor.assumeIsolated {
            self.logger.info(
                "Failed to connect to \(peripheral.identifier.uuidString, privacy: .public): \(reason, privacy: .public)"
            )
            // Transient first-connect failures (device out of range, brief radio glitch)
            // used to stay in `.failed` forever. Share the disconnect backoff so they
            // recover automatically, and only surface a permanent failure after the ceiling.
            guard let source = self.store?.source(id: peripheral.identifier.uuidString),
                  source.isEnabled
            else {
                self.connectionStates[peripheral.identifier] = .failed(reason)
                return
            }
            self.connectionStates[peripheral.identifier] = .disconnected
            self.scheduleReconnect(
                peripheral,
                gaveUpReason: "Could not connect. Use Reconnect to try again."
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.connectionStates[peripheral.identifier] = .disconnected
            // The HRV window is only meaningful over a continuous recording, so a
            // disconnection invalidates it rather than pausing it.
            self.hrvAccumulators[peripheral.identifier]?.reset()
            self.readingAdmission.reset(sourceID: peripheral.identifier.uuidString)
            self.hrvProgress[peripheral.identifier] = nil
            self.hrvQuality[peripheral.identifier] = nil
            self.pulseOximeterQuality[peripheral.identifier] = nil
            self.discoveryStates[peripheral.identifier] = nil
            self.streamStallTasks[peripheral.identifier]?.cancel()
            self.streamStallTasks[peripheral.identifier] = nil

            // Rings drop out constantly. Reconnect automatically as long as the source is
            // still enabled, but with a backoff: an immediate retry against a device that
            // is dropping every second is a tight loop with no end state.
            guard let source = self.store?.source(id: peripheral.identifier.uuidString),
                  source.isEnabled
            else { return }
            self.scheduleReconnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // `[CBPeripheral]` is not Sendable, so handing the array to the main actor trips
        // region isolation. It is sound here for the same reason the `assumeIsolated`
        // hops are: the central was created with a nil queue, so this callback is already
        // running on the main queue and no second thread can observe these objects.
        nonisolated(unsafe) let restored =
            dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            // iOS relaunched the app to hand back live connections. Re-adopt them and
            // re-attach the delegate, otherwise notifications arrive nowhere.
            for peripheral in restored {
                self.peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                if peripheral.state == .connected {
                    self.discoverServices(on: peripheral)
                }
            }
            self.logger.info("Restored \(restored.count) peripheral(s) from background")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated {
            if let error {
                self.connectionStates[peripheral.identifier] = .failed(error.localizedDescription)
                return
            }
            let services = peripheral.services ?? []
            guard !services.isEmpty else {
                self.connectionStates[peripheral.identifier] =
                    .unsupported("This device exposes no supported health service. Confirm it uses a standard Heart Rate, Pulse Oximeter, or Health Thermometer profile.")
                return
            }
            var serviceIDs: Set<String> = []
            for (index, service) in services.enumerated() {
                let serviceID = "\(service.uuid.uuidString)#\(index)"
                self.serviceDiscoveryIDs[ObjectIdentifier(service)] = serviceID
                serviceIDs.insert(serviceID)
            }
            self.discoveryStates[peripheral.identifier] = BluetoothDiscoveryState(serviceIDs: serviceIDs)
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard var discovery = self.discoveryStates[peripheral.identifier],
                  let serviceID = self.serviceDiscoveryIDs[ObjectIdentifier(service)]
            else { return }
            let characteristics = service.characteristics ?? []
            var candidates: [BluetoothDiscoveryState.Candidate] = []
            for characteristic in characteristics {
                if GATT.notifyCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.notify)
                       || characteristic.properties.contains(.indicate) {
                    if let candidate = self.subscriptionCandidate(for: characteristic) {
                        candidates.append(candidate)
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
                if GATT.readOnceCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
            discovery.finishService(
                id: serviceID,
                candidates: candidates,
                errorDescription: error?.localizedDescription
            )
            self.discoveryStates[peripheral.identifier] = discovery
            self.applyDiscoveryResolution(for: peripheral.identifier)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            if let error {
                self.connectionStates[peripheral.identifier] = (
                    self.connectionStates[peripheral.identifier] ?? .disconnected
                ).stalled(
                    "A measurement update failed: \(error.localizedDescription). Use Reconnect if it continues."
                )
                return
            }
            guard let data = characteristic.value else { return }
            switch characteristic.uuid {
            case GATT.heartRateMeasurement:
                self.handleHeartRate(data, from: peripheral)
            case GATT.plxContinuousMeasurement:
                self.handlePulseOximeter(data, from: peripheral, isSpotCheck: false)
            case GATT.plxSpotCheckMeasurement:
                self.handlePulseOximeter(data, from: peripheral, isSpotCheck: true)
            case GATT.temperatureMeasurement, GATT.intermediateTemperature:
                self.handleTemperature(data, from: peripheral)
            case GATT.batteryLevel:
                self.handleBattery(data, from: peripheral)
            case GATT.bodySensorLocation:
                self.handleBodySensorLocation(data, from: peripheral)
            case GATT.manufacturerNameString, GATT.modelNumberString, GATT.firmwareRevisionString:
                self.handleDeviceInfo(characteristic, from: peripheral)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard let subscriptionID = self.characteristicSubscriptionIDs[ObjectIdentifier(characteristic)],
                  var discovery = self.discoveryStates[peripheral.identifier]
            else { return }
            let subscriptionError = error?.localizedDescription
                ?? (characteristic.isNotifying ? nil : "Peripheral declined notifications")
            discovery.finishSubscription(id: subscriptionID, errorDescription: subscriptionError)
            self.discoveryStates[peripheral.identifier] = discovery
            if let error {
                self.logger.error(
                    "Failed to subscribe to \(characteristic.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            self.applyDiscoveryResolution(for: peripheral.identifier)
        }
    }
}
