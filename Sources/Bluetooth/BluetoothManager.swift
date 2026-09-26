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
    /// Evidence for each peripheral's current connection: inventory, packet counts before
    /// parsing, named rejections, commands, and (in a diagnostic session only) raw packets.
    private(set) var diagnostics: [UUID: BluetoothDiagnostics] = [:]
    /// Vendor ring sessions for peripherals whose GATT topology matched `R11MRingSession`.
    private(set) var ringSessions: [UUID: R11MRingSession] = [:]

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

    /// Increments on every app-side connection (and every restored or rediscovered link).
    /// Delayed work captures the value and does nothing if a newer session has begun.
    private var connectionSessions: [UUID: Int] = [:]
    /// Peripherals whose explicit Reconnect is waiting for the old link's disconnect callback.
    private var pendingFreshReconnects: Set<UUID> = []
    private var freshReconnectFallbacks: [UUID: Task<Void, Never>] = [:]
    /// Peripherals whose next discovery inventories every service (a diagnostic session).
    private var fullDiscoveryRequested: Set<UUID> = []
    /// Metrics accepted on the current connection. Late discovery callbacks cannot erase it.
    private var observedMetrics: [UUID: Set<MetricKind>] = [:]
    private var streamCadences: [UUID: StreamCadence] = [:]
    /// Diagnostic key for each discovered characteristic.
    private var characteristicKeys: [ObjectIdentifier: String] = [:]
    private var ringCharacteristics: [UUID: [R11MRingSession.Channel: CBCharacteristic]] = [:]
    private var ringAssemblers: [UUID: [R11MRingSession.Channel: YCBTFrameAssembler]] = [:]
    private var ringTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// Purposes of vendor writes awaiting `didWriteValueFor`, oldest first.
    private var pendingRingWrites: [UUID: [R11MRingSession.Purpose]] = [:]

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
            // A foreground refresh reaches here for every known device. A connection whose
            // discovery is under way or finished is left alone: rediscovering would reset a
            // ring measurement and overwrite observed streaming state. Only a connected link
            // HeartSync has never interrogated (for example after restoration) is discovered.
            if discoveryStates[peripheral.identifier] == nil {
                discoverServices(on: peripheral)
            }
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
        cancelFreshReconnect(for: uuid)
        cancelPendingReconnect(for: uuid)
        fullDiscoveryRequested.remove(uuid)
        // Stop a running ring measurement while the link can still carry the command.
        stopRingMeasurement(on: peripheral)
        central.cancelPeripheralConnection(peripheral)
        endConnectionSession(for: uuid)
        connectionStates[uuid] = .disconnected
    }

    /// User-initiated reconnection: a fresh app connection session, not a rediscovery on
    /// the old link.
    ///
    /// Clears the backoff, because an explicit tap is the signal that whatever was wrong
    /// (device off, out of range) has been dealt with. A connected peripheral is
    /// disconnected first, and the new connection starts only from its terminal disconnect
    /// callback, so discovery, subscriptions, and any vendor initialization run again
    /// exactly once. The automatic backoff is bypassed for that disconnect so it cannot
    /// schedule a duplicate connection.
    func reconnect(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID) else { return }
        cancelPendingReconnect(for: uuid)
        reconnectAttempts[uuid] = nil
        guard let peripheral = peripherals[uuid] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
        peripherals[uuid] = peripheral
        beginFreshSession(peripheral)
    }

    /// Runs a bounded diagnostic session on one device: a fresh connection whose discovery
    /// inventories every service and characteristic, and a short raw-packet capture. The
    /// result is read with `diagnosticsReport(forSource:deviceName:)`.
    func runDiagnostics(sourceID: String) {
        guard isPoweredOn, let uuid = UUID(uuidString: sourceID) else { return }
        fullDiscoveryRequested.insert(uuid)
        reconnect(sourceID: sourceID)
    }

    func diagnosticsReport(forSource sourceID: String, deviceName: String) -> String? {
        guard let uuid = UUID(uuidString: sourceID) else { return nil }
        return diagnostics[uuid]?.exportText(deviceName: deviceName)
    }

    private func beginFreshSession(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        cancelFreshReconnect(for: id)
        switch peripheral.state {
        case .connected, .disconnecting:
            stopRingMeasurement(on: peripheral)
            endConnectionSession(for: id)
            pendingFreshReconnects.insert(id)
            connectionStates[id] = .connecting
            if peripheral.state == .connected {
                central.cancelPeripheralConnection(peripheral)
            }
            // The disconnect callback normally arrives within a second. If it never does,
            // reconnect anyway rather than leaving the row in "Connecting" forever.
            let session = connectionSessions[id]
            freshReconnectFallbacks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self,
                      self.connectionSessions[id] == session,
                      self.pendingFreshReconnects.remove(id) != nil
                else { return }
                self.freshReconnectFallbacks[id] = nil
                guard self.isPoweredOn, let peripheral = self.peripherals[id] else { return }
                self.connect(peripheral)
            }
        default:
            // Disconnected, or a connection still pending: issuing the connect is enough.
            endConnectionSession(for: id)
            connect(peripheral)
        }
    }

    private func cancelFreshReconnect(for id: UUID) {
        pendingFreshReconnects.remove(id)
        freshReconnectFallbacks[id]?.cancel()
        freshReconnectFallbacks[id] = nil
    }

    /// Discards everything that belongs to one app connection session of one peripheral.
    /// Persistent facts (source, history, diagnostics of the ended session) are kept.
    private func endConnectionSession(for id: UUID) {
        discoveryStates[id] = nil
        streamStallTasks[id]?.cancel()
        streamStallTasks[id] = nil
        observedMetrics[id] = nil
        streamCadences[id] = nil
        ringSessions[id] = nil
        ringCharacteristics[id] = nil
        ringAssemblers[id] = nil
        ringTimeoutTasks[id]?.cancel()
        ringTimeoutTasks[id] = nil
        pendingRingWrites[id] = nil
    }

    func forget(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID) else { return }
        cancelFreshReconnect(for: uuid)
        fullDiscoveryRequested.remove(uuid)
        if let peripheral = peripherals[uuid] {
            stopRingMeasurement(on: peripheral)
            central.cancelPeripheralConnection(peripheral)
        }
        endConnectionSession(for: uuid)
        diagnostics[uuid] = nil
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
        let id = peripheral.identifier
        connectionStates[id] = .linkConnected
        endConnectionSession(for: id)
        connectionSessions[id, default: 0] += 1
        let fullDiscovery = fullDiscoveryRequested.remove(id) != nil
        diagnostics[id] = BluetoothDiagnostics(
            startedAt: .now,
            connectionSession: connectionSessions[id] ?? 0,
            fullDiscovery: fullDiscovery
        )
        peripheral.delegate = self
        // Ordinarily pass an explicit list rather than nil: discovering every service on a
        // chatty device costs seconds and yields nothing this app can read. Only an explicit
        // diagnostic session inventories everything.
        peripheral.discoverServices(fullDiscovery ? nil : GATT.discoverServices)
        connectionStates[id] = .discoveringServices
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
        let peripheralID = UUID(uuidString: sourceID)
        guard kind.plausibleRange.contains(value) else {
            if let peripheralID { diagnostics[peripheralID]?.reject(.outOfRange) }
            return false
        }
        guard readingAdmission.accept(sourceID: sourceID, kind: kind, receivedAt: receivedAt) else {
            if let peripheralID { diagnostics[peripheralID]?.reject(.throttled) }
            return false
        }
        // Forwarded, not confirmed saved: `onReading` returns nothing about the commit.
        if let peripheralID { diagnostics[peripheralID]?.accept(kind, value: value, at: receivedAt) }
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

    private func note(metric: MetricKind, for peripheralID: UUID, at date: Date = .now) {
        observedMetrics[peripheralID, default: []].insert(metric)
        streamCadences[peripheralID, default: StreamCadence()].record(date)
        // An on-demand ring reading is a completed spot measurement. It keeps its own
        // timestamp and ages normally; it is not a continuous stream that "stalls".
        if let ring = ringSessions[peripheralID], ring.suppressesStandardHeartRate {
            applyDiscoveryResolution(for: peripheralID)
            return
        }
        streamStallTasks[peripheralID]?.cancel()
        streamStallTasks[peripheralID] = nil
        let state = (connectionStates[peripheralID] ?? .disconnected).receiving(metric)
        connectionStates[peripheralID] = state
        if case .streaming = state {
            scheduleStreamStallCheck(for: peripheralID)
        }
    }

    private func applyDiscoveryResolution(for peripheralID: UUID) {
        guard let discovery = discoveryStates[peripheralID] else { return }
        let ring = ringSessions[peripheralID]
        diagnostics[peripheralID]?.ringPhase = ring?.statusText
        let onDemand = ring?.suppressesStandardHeartRate == true
        let (state, armsWatchdog) = PeripheralConnectionState.resolving(
            discovery.resolution,
            current: connectionStates[peripheralID] ?? .disconnected,
            // A ring's spot reading is shown by the ring status, not as a stream.
            observed: onDemand ? [] : observedMetrics[peripheralID] ?? [],
            onDemandStatus: onDemand ? ring?.statusText : nil,
            adapterWarning: onDemand ? nil : ring?.statusText
        )
        connectionStates[peripheralID] = state
        if armsWatchdog {
            scheduleStreamStallCheck(for: peripheralID)
        }
    }

    /// Arms the no-data watchdog. The wait follows the stream's observed cadence
    /// (`StreamCadence`), and the message says what the evidence shows: silence, rejected
    /// packets, or a stream that stopped. It changes only the displayed state; a later valid
    /// value recovers the stream.
    private func scheduleStreamStallCheck(for peripheralID: UUID) {
        streamStallTasks[peripheralID]?.cancel()
        let threshold = streamCadences[peripheralID]?.stallThreshold ?? StreamCadence.initialAcquisitionBudget
        let session = connectionSessions[peripheralID]
        streamStallTasks[peripheralID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(threshold))
            guard !Task.isCancelled, let self,
                  self.connectionSessions[peripheralID] == session
            else { return }
            let current = self.connectionStates[peripheralID] ?? .disconnected
            let diagnosis: BluetoothDiagnostics.StallDiagnosis
            switch current {
            case .ready:
                diagnosis = self.diagnostics[peripheralID]?.stallDiagnosis ?? .noPackets
            case .streaming:
                diagnosis = self.diagnostics[peripheralID]?.stallDiagnosis ?? .streamStopped
            default:
                return
            }
            self.connectionStates[peripheralID] = current.stalled(diagnosis.message(seconds: Int(threshold)))
        }
    }

    private func subscriptionCandidate(for characteristic: CBCharacteristic) -> BluetoothDiscoveryState.Candidate? {
        let metrics: Set<MetricKind>
        switch characteristic.uuid {
        case GATT.heartRateMeasurement:
            // Heart rate only. HRV is derived, and becomes available only after real
            // R\u{2013}R intervals meet the accumulator's requirements; a subscription is not
            // evidence that the sensor sends them.
            metrics = [.heartRate]
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

    /// A vendor control channel: required for the ring session, but never a metric.
    private func controlChannelCandidate(for characteristic: CBCharacteristic) -> BluetoothDiscoveryState.Candidate {
        let id = "\(characteristic.uuid.uuidString)#\(ObjectIdentifier(characteristic).hashValue)"
        characteristicSubscriptionIDs[ObjectIdentifier(characteristic)] = id
        return BluetoothDiscoveryState.Candidate(id: id, metrics: [])
    }

    fileprivate func handleHeartRate(_ data: Data, from peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let measurement = HeartRateMeasurement(data: data) else {
            diagnostics[id]?.reject(.malformed)
            logger.debug("Unparseable HR frame, \(data.count) bytes")
            return
        }
        let sourceID = id.uuidString
        let now = Date.now

        // A ring whose vendor protocol owns heart rate also re-notifies the standard
        // characteristic; ingesting both would duplicate its readings, and the standard
        // value can be a repeat rather than a fresh measurement.
        if ringSessions[id]?.suppressesStandardHeartRate == true {
            diagnostics[id]?.reject(.supersededByRingProtocol)
            return
        }
        // A sensor that supports contact detection and says it is off-body is reporting
        // noise. Storing it would generate a large, meaningless discrepancy.
        if measurement.isSensorContactDetected == false {
            diagnostics[id]?.reject(.offBody)
            return
        }
        guard readingAdmission.acceptNotification(
            sourceID: sourceID,
            channel: .heartRate,
            receivedAt: now
        ) else {
            diagnostics[id]?.reject(.throttled)
            return
        }

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
        guard let measurement = parsed else {
            diagnostics[peripheral.identifier]?.reject(.malformed)
            return
        }
        let quality = measurement.quality(for: isSpotCheck ? .spotCheck : .continuous)
        pulseOximeterQuality[peripheral.identifier] = (quality, measurement.pulseAmplitudeIndex)
        let values = PulseOximeterIngestionPolicy.durableValues(
            from: measurement,
            sampleType: isSpotCheck ? .spotCheck : .continuous
        )
        guard !values.isEmpty else {
            diagnostics[peripheral.identifier]?.reject(.invalidQuality)
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
            diagnostics[id]?.reject(.invalidTimestamp)
            logger.debug("Rejected pulse-oximeter timestamp outside the accepted receipt window")
            return
        }
        for durableValue in values {
            let admitted = readingAdmission.acceptNotification(
                sourceID: sourceID,
                channel: durableValue.channel,
                receivedAt: receivedAt
            )
            guard admitted else {
                diagnostics[id]?.reject(.throttled)
                continue
            }
            if emit(sourceID: sourceID, kind: durableValue.kind, value: durableValue.value,
                    start: timestamp, provenance: .measured, metadata: durableValue.metadata,
                    receivedAt: receivedAt) {
                note(metric: durableValue.kind, for: id)
            }
        }
    }

    fileprivate func handleTemperature(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = TemperatureMeasurement(data: data) else {
            diagnostics[peripheral.identifier]?.reject(.malformed)
            return
        }
        let receivedAt = Date.now
        guard let timestamp = BluetoothTimestampPolicy.normalized(
            deviceTimestamp: measurement.timestamp,
            receivedAt: receivedAt,
            maximumAge: store?.retention ?? BluetoothTimestampPolicy.defaultMaximumAge
        ) else {
            diagnostics[peripheral.identifier]?.reject(.invalidTimestamp)
            logger.debug("Rejected thermometer timestamp outside the accepted receipt window")
            return
        }
        let sourceID = peripheral.identifier.uuidString
        guard readingAdmission.acceptNotification(
            sourceID: sourceID,
            channel: .temperature,
            receivedAt: receivedAt
        ) else {
            diagnostics[peripheral.identifier]?.reject(.throttled)
            return
        }
        if emit(sourceID: sourceID, kind: .bodyTemperature, value: measurement.celsius,
                start: timestamp, provenance: .measured, receivedAt: receivedAt) {
            note(metric: .bodyTemperature, for: peripheral.identifier)
        }
    }

    // MARK: Vendor ring session

    /// Whether the source is a ring with a vendor session, and what it can do now.
    func ringSession(forSource sourceID: String) -> R11MRingSession? {
        guard let uuid = UUID(uuidString: sourceID) else { return nil }
        return ringSessions[uuid]
    }

    /// Starts one on-demand heart-rate measurement on an identified ring.
    func measureHeartRate(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID),
              let peripheral = peripherals[uuid],
              peripheral.state == .connected,
              var session = ringSessions[uuid]
        else { return }
        let actions = session.startHeartRate()
        ringSessions[uuid] = session
        performRingActions(actions, on: peripheral)
        applyDiscoveryResolution(for: uuid)
    }

    func cancelRingMeasurement(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID), let peripheral = peripherals[uuid] else { return }
        stopRingMeasurement(on: peripheral)
        applyDiscoveryResolution(for: uuid)
    }

    /// Sends the stop command for a running measurement, when the link can still carry it.
    private func stopRingMeasurement(on peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard var session = ringSessions[id], session.isMeasuring else { return }
        let actions = session.cancel()
        ringSessions[id] = session
        guard peripheral.state == .connected else { return }
        performRingActions(actions, on: peripheral)
    }

    fileprivate func handleRingData(
        _ data: Data,
        channel: R11MRingSession.Channel,
        from peripheral: CBPeripheral
    ) {
        let id = peripheral.identifier
        guard ringSessions[id] != nil else { return }
        let now = Date.now
        var assembler = ringAssemblers[id]?[channel] ?? YCBTFrameAssembler()
        let outputs = assembler.append(data)
        ringAssemblers[id, default: [:]][channel] = assembler

        for output in outputs {
            switch output {
            case .rejected(.crcMismatch):
                diagnostics[id]?.reject(.crcMismatch)
            case .rejected(.invalidLength):
                diagnostics[id]?.reject(.invalidFrameLength)
            case .frame(let frame):
                guard var session = ringSessions[id] else { return }
                let message = YCBTFrameCodec.message(for: frame)
                switch message {
                case .liveHeartRate where session.isMeasuring:
                    diagnostics[id]?.reject(.provisional)
                case .truncated:
                    diagnostics[id]?.reject(.malformed)
                case .deviceInfo(let length):
                    diagnostics[id]?.adapterNote = "Identity reply received (\(length)-byte payload)."
                default:
                    break
                }
                let actions = session.received(message, at: now)
                ringSessions[id] = session
                performRingActions(actions, on: peripheral)
            }
        }
        applyDiscoveryResolution(for: id)
    }

    private func performRingActions(_ actions: [R11MRingSession.Action], on peripheral: CBPeripheral) {
        let id = peripheral.identifier
        for action in actions {
            switch action {
            case .write(let data, let purpose):
                guard let characteristic = ringCharacteristics[id]?[.command],
                      let session = ringSessions[id]
                else { continue }
                diagnostics[id]?.recordCommand(purpose: purpose.rawValue, bytes: data.count, at: .now)
                if session.writeWithResponse {
                    pendingRingWrites[id, default: []].append(purpose)
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                } else {
                    // No transport callback exists for this write type; the ring's reply is
                    // the only evidence, and the session waits for it.
                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                    diagnostics[id]?.recordWrite(purpose: purpose.rawValue, error: nil)
                }

            case .scheduleTimeout(let timeout, let seconds, let token):
                ringTimeoutTasks[id]?.cancel()
                let session = connectionSessions[id]
                ringTimeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled, let self,
                          self.connectionSessions[id] == session,
                          var ring = self.ringSessions[id],
                          let peripheral = self.peripherals[id]
                    else { return }
                    self.ringTimeoutTasks[id] = nil
                    let actions = ring.timeoutElapsed(timeout, token: token)
                    self.ringSessions[id] = ring
                    if peripheral.state == .connected {
                        self.performRingActions(actions, on: peripheral)
                    }
                    self.applyDiscoveryResolution(for: id)
                }

            case .emitHeartRate(let bpm, let measuredAt):
                // The same Bluetooth source, the same `emit` → `AppModel.ingest` →
                // `HealthStore` path, and the same plausibility and admission rules as a
                // standard heart-rate frame.
                if emit(
                    sourceID: id.uuidString,
                    kind: .heartRate,
                    value: Double(bpm),
                    start: measuredAt,
                    provenance: .measured,
                    receivedAt: .now
                ) {
                    note(metric: .heartRate, for: id, at: measuredAt)
                }
            }
        }
    }

    fileprivate func handleRingWriteResult(for peripheral: CBPeripheral, error: (any Error)?) {
        let id = peripheral.identifier
        guard var pending = pendingRingWrites[id], !pending.isEmpty else { return }
        let purpose = pending.removeFirst()
        pendingRingWrites[id] = pending
        diagnostics[id]?.recordWrite(purpose: purpose.rawValue, error: error?.localizedDescription)
        guard var session = ringSessions[id] else { return }
        let actions = session.writeFinished(purpose, error: error?.localizedDescription)
        ringSessions[id] = session
        performRingActions(actions, on: peripheral)
        applyDiscoveryResolution(for: id)
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
        diagnostics[id]?.deviceIdentity = combined.isEmpty ? nil : combined
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
                // An explicit Reconnect cannot complete without a radio either.
                for id in self.pendingFreshReconnects { self.cancelFreshReconnect(for: id) }
                for id in Array(self.discoveryStates.keys) { self.endConnectionSession(for: id) }
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
            let id = peripheral.identifier
            self.connectionStates[id] = .disconnected
            // The HRV window is only meaningful over a continuous recording, so a
            // disconnection invalidates it rather than pausing it.
            self.hrvAccumulators[id]?.reset()
            self.readingAdmission.reset(sourceID: id.uuidString)
            self.hrvProgress[id] = nil
            self.hrvQuality[id] = nil
            self.pulseOximeterQuality[id] = nil
            // Pending vendor writes, timers, and half-assembled frames die with the link.
            self.endConnectionSession(for: id)

            // An explicit Reconnect was waiting for exactly this callback. Connect once,
            // now, and skip the automatic backoff so it cannot schedule a second attempt.
            if self.pendingFreshReconnects.contains(id) {
                self.cancelFreshReconnect(for: id)
                guard self.isPoweredOn,
                      let source = self.store?.source(id: id.uuidString), source.isEnabled
                else { return }
                self.connect(peripheral)
                return
            }

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
                self.diagnostics[peripheral.identifier]?.recordCallbackError(key: nil, "Service discovery: \(error.localizedDescription)")
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
            let id = peripheral.identifier
            let characteristics = service.characteristics ?? []
            let fullDiscovery = self.diagnostics[id]?.fullDiscovery == true
            var candidates: [BluetoothDiscoveryState.Candidate] = []

            // A vendor ring adapter is chosen from topology, never from the advertised name.
            var ringChannels: [CBUUID: R11MRingSession.Channel] = [:]
            if service.uuid == GATT.ycbtService {
                let traits = Dictionary(
                    characteristics.map { ($0.uuid.uuidString, Self.ringTraits($0.properties)) },
                    uniquingKeysWith: { first, _ in first }
                )
                switch R11MRingSession.match(services: [service.uuid.uuidString: traits]) {
                case .matched(let writeWithResponse):
                    self.ringSessions[id] = R11MRingSession(writeWithResponse: writeWithResponse)
                    self.diagnostics[id]?.selectedAdapter = "YCBT vendor ring protocol (candidate; identity query pending)"
                    ringChannels = [GATT.ycbtCommand: .command, GATT.ycbtEvents: .events]
                case .notMatched(let reason):
                    self.diagnostics[id]?.adapterNote = "Vendor service present but not used: \(reason)."
                }
            }

            for characteristic in characteristics {
                let key = "\(service.uuid.uuidString)/\(characteristic.uuid.uuidString)#\(ObjectIdentifier(characteristic).hashValue)"
                self.characteristicKeys[ObjectIdentifier(characteristic)] = key
                self.diagnostics[id]?.recordCharacteristic(
                    key: key,
                    uuid: characteristic.uuid.uuidString,
                    serviceUUID: service.uuid.uuidString,
                    properties: Self.propertyNames(characteristic.properties)
                )
                let canSubscribe = characteristic.properties.contains(.notify)
                    || characteristic.properties.contains(.indicate)
                if GATT.notifyCharacteristics.contains(characteristic.uuid), canSubscribe {
                    if let candidate = self.subscriptionCandidate(for: characteristic) {
                        candidates.append(candidate)
                        self.diagnostics[id]?.recordSubscription(key: key, status: .pending)
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                } else if let channel = ringChannels[characteristic.uuid] {
                    self.ringCharacteristics[id, default: [:]][channel] = characteristic
                    candidates.append(self.controlChannelCandidate(for: characteristic))
                    self.diagnostics[id]?.recordSubscription(key: key, status: .pending)
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if fullDiscovery, canSubscribe {
                    // Diagnostic session only: listen to unknown channels to count packets.
                    // They never become readiness candidates or readings.
                    self.diagnostics[id]?.recordSubscription(key: key, status: .pending)
                    peripheral.setNotifyValue(true, for: characteristic)
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
            let id = peripheral.identifier
            let key = self.characteristicKeys[ObjectIdentifier(characteristic)]
            if let error {
                self.diagnostics[id]?.recordCallbackError(key: key, error.localizedDescription)
                self.connectionStates[id] = (
                    self.connectionStates[id] ?? .disconnected
                ).stalled(
                    "A measurement update failed: \(error.localizedDescription). Use Reconnect if it continues."
                )
                return
            }
            guard let data = characteristic.value else { return }
            // Counted before any parser or admission guard, so silence and rejection differ.
            if let key {
                self.diagnostics[id]?.recordPacket(
                    key: key,
                    data: data,
                    at: .now,
                    isMeasurement: GATT.measurementCharacteristics.contains(characteristic.uuid)
                )
            }
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
            case GATT.ycbtCommand:
                self.handleRingData(data, channel: .command, from: peripheral)
            case GATT.ycbtEvents:
                self.handleRingData(data, channel: .events, from: peripheral)
            default:
                self.diagnostics[id]?.reject(.unknownCharacteristic)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            let subscriptionError = error?.localizedDescription
                ?? (characteristic.isNotifying ? nil : "Peripheral declined notifications")
            if let key = self.characteristicKeys[ObjectIdentifier(characteristic)] {
                self.diagnostics[id]?.recordSubscription(
                    key: key,
                    status: subscriptionError.map(BluetoothDiagnostics.SubscriptionStatus.failed) ?? .subscribed
                )
            }
            guard let subscriptionID = self.characteristicSubscriptionIDs[ObjectIdentifier(characteristic)],
                  var discovery = self.discoveryStates[id]
            else { return }
            discovery.finishSubscription(id: subscriptionID, errorDescription: subscriptionError)
            self.discoveryStates[id] = discovery

            // Both vendor channels must confirm before the ring session sends anything.
            let ringChannel: R11MRingSession.Channel? = switch characteristic.uuid {
            case GATT.ycbtCommand: .command
            case GATT.ycbtEvents: .events
            default: nil
            }
            if let ringChannel, var session = self.ringSessions[id] {
                let actions = session.subscriptionFinished(ringChannel, error: subscriptionError)
                self.ringSessions[id] = session
                self.performRingActions(actions, on: peripheral)
            }
            if let error {
                self.logger.error(
                    "Failed to subscribe to \(characteristic.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            self.applyDiscoveryResolution(for: peripheral.identifier)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == GATT.ycbtCommand else { return }
            self.handleRingWriteResult(for: peripheral, error: error)
        }
    }
}

extension BluetoothManager {
    fileprivate static func ringTraits(_ properties: CBCharacteristicProperties) -> R11MRingSession.Traits {
        var traits: R11MRingSession.Traits = []
        if properties.contains(.write) { traits.insert(.write) }
        if properties.contains(.writeWithoutResponse) { traits.insert(.writeWithoutResponse) }
        if properties.contains(.notify) { traits.insert(.notify) }
        if properties.contains(.indicate) { traits.insert(.indicate) }
        if properties.contains(.read) { traits.insert(.read) }
        return traits
    }

    fileprivate static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"),
            (.write, "write"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.broadcast, "broadcast"),
            (.authenticatedSignedWrites, "signedWrite"),
            (.extendedProperties, "extended"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1)
    }
}
