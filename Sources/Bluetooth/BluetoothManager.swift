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
    case discoveringServices
    /// Connected and subscribed. The associated set is the metrics being received.
    case streaming(Set<MetricKind>)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .discoveringServices, .streaming: true
        case .disconnected, .failed: false
        }
    }

    var title: String {
        switch self {
        case .disconnected:        "Not connected"
        case .connecting:          "Connecting\u{2026}"
        case .discoveringServices: "Reading services\u{2026}"
        case .streaming(let kinds):
            kinds.isEmpty ? "Connected" : "Streaming \(kinds.count) metric\(kinds.count == 1 ? "" : "s")"
        case .failed(let reason):  reason
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

    /// When true the scan reports every peripheral, not just ones advertising a health
    /// service. Many inexpensive rings omit their service UUIDs from the advertisement
    /// packet and only reveal them after connecting, so this is the fallback that makes
    /// them findable.
    var scanForAllDevices = false

    var isPoweredOn: Bool { state == .poweredOn }

    var stateDescription: String {
        switch state {
        case .poweredOn:   "Ready"
        case .poweredOff:  "Bluetooth is off. Turn it on in Settings or Control Centre."
        case .unauthorized:"HeartSync is not allowed to use Bluetooth. Enable it in Settings \u{203A} HeartSync."
        case .unsupported: "This device does not support Bluetooth Low Energy."
        case .resetting:   "Bluetooth is restarting\u{2026}"
        case .unknown:     "Checking Bluetooth\u{2026}"
        @unknown default:  "Unavailable"
        }
    }

    // MARK: Private state

    private var central: CBCentralManager!
    /// Strong references are mandatory: CoreBluetooth does not retain peripherals, and a
    /// released `CBPeripheral` silently stops delivering notifications.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var hrvAccumulators: [UUID: HRVAccumulator] = [:]
    private var pendingModelInfo: [UUID: (manufacturer: String?, model: String?)] = [:]
    private var scanTimeoutTask: Task<Void, Never>?

    private weak var store: HealthStore?
    private var onReading: (@MainActor (Reading) -> Void)?

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
    }

    func stopScan() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        guard isScanning else { return }
        isScanning = false
        central?.stopScan()
        logger.info("Scan stopped")
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

    func reconnect(sourceID: String) {
        guard let uuid = UUID(uuidString: sourceID) else { return }
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
        peripherals[uuid] = nil
        connectionStates[uuid] = nil
        hrvAccumulators[uuid] = nil
        hrvProgress[uuid] = nil
    }

    func connectionState(forSource id: String) -> PeripheralConnectionState {
        guard let uuid = UUID(uuidString: id) else { return .disconnected }
        return connectionStates[uuid] ?? .disconnected
    }

    private func discoverServices(on peripheral: CBPeripheral) {
        connectionStates[peripheral.identifier] = .discoveringServices
        peripheral.delegate = self
        // Pass an explicit list rather than nil: discovering every service on a chatty
        // device costs seconds and yields nothing this app can read.
        peripheral.discoverServices(GATT.discoverServices)
    }

    // MARK: Ingest

    private func emit(_ reading: Reading) {
        onReading?(reading)
    }

    private func note(metric: MetricKind, for peripheralID: UUID) {
        if case .streaming(var kinds) = connectionStates[peripheralID] ?? .disconnected {
            guard !kinds.contains(metric) else { return }
            kinds.insert(metric)
            connectionStates[peripheralID] = .streaming(kinds)
        } else {
            connectionStates[peripheralID] = .streaming([metric])
        }
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

        emit(Reading(
            sourceID: sourceID,
            kind: .heartRate,
            value: Double(measurement.beatsPerMinute),
            start: now,
            provenance: .measured
        ))
        note(metric: .heartRate, for: id)

        guard !measurement.rrIntervalsMS.isEmpty else { return }
        var accumulator = hrvAccumulators[id] ?? HRVAccumulator()
        accumulator.add(intervals: measurement.rrIntervalsMS, at: now)
        hrvProgress[id] = (accumulator.bufferedBeats, accumulator.bufferedDuration)

        if let metrics = accumulator.emitIfReady(at: now) {
            let windowStart = now.addingTimeInterval(-accumulator.window)
            emit(Reading(sourceID: sourceID, kind: .hrvRMSSD, value: metrics.rmssd,
                         start: windowStart, end: now, provenance: .derived))
            emit(Reading(sourceID: sourceID, kind: .hrvSDNN, value: metrics.sdnn,
                         start: windowStart, end: now, provenance: .derived))
            note(metric: .hrvRMSSD, for: id)
            note(metric: .hrvSDNN, for: id)
        }
        hrvAccumulators[id] = accumulator
    }

    fileprivate func handlePulseOximeter(_ data: Data, from peripheral: CBPeripheral, isSpotCheck: Bool) {
        let parsed = isSpotCheck
            ? PulseOximeterMeasurement.spotCheck(data: data)
            : PulseOximeterMeasurement.continuous(data: data)
        guard let measurement = parsed else { return }
        // The device's own status bits are more reliable than any heuristic here.
        guard !measurement.isDeviceReportedInvalid else {
            logger.debug("Pulse oximeter reported an invalid measurement; skipping")
            return
        }

        let id = peripheral.identifier
        let sourceID = id.uuidString
        let timestamp = measurement.timestamp ?? .now

        if let spo2 = measurement.spo2Percent {
            emit(Reading(sourceID: sourceID, kind: .spo2, value: spo2,
                         start: timestamp, provenance: .measured))
            note(metric: .spo2, for: id)
        }
        if let pulse = measurement.pulseRateBPM {
            emit(Reading(sourceID: sourceID, kind: .heartRate, value: pulse,
                         start: timestamp, provenance: .measured))
            note(metric: .heartRate, for: id)
        }
    }

    fileprivate func handleTemperature(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = TemperatureMeasurement(data: data) else { return }
        emit(Reading(
            sourceID: peripheral.identifier.uuidString,
            kind: .bodyTemperature,
            value: measurement.celsius,
            start: measurement.timestamp ?? .now,
            provenance: .measured
        ))
        note(metric: .bodyTemperature, for: peripheral.identifier)
    }

    fileprivate func handleBattery(_ data: Data, from peripheral: CBPeripheral) {
        var reader = BinaryReader(data)
        guard let percent = reader.uint8(), percent <= 100 else { return }
        store?.updateBattery(Int(percent), forSource: peripheral.identifier.uuidString)
    }

    fileprivate func handleDeviceInfo(_ characteristic: CBCharacteristic, from peripheral: CBPeripheral) {
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        let id = peripheral.identifier
        var info = pendingModelInfo[id] ?? (nil, nil)
        switch characteristic.uuid {
        case GATT.manufacturerNameString: info.manufacturer = text
        case GATT.modelNumberString:      info.model = text
        default: return
        }
        pendingModelInfo[id] = info

        let combined = [info.manufacturer, info.model]
            .compactMap { $0 }
            .joined(separator: " ")
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
                self.isScanning = false
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
            self.peripherals[id] = peripheral

            // RSSI of 127 is CoreBluetooth's "not available" sentinel, not a strong signal.
            let entry = DiscoveredPeripheral(
                id: id,
                name: name,
                rssi: rssi == 127 ? -100 : rssi,
                advertisedServices: services,
                isConnectable: connectable,
                lastSeen: .now
            )
            if let index = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[index] = entry
            } else {
                self.discovered.append(entry)
            }
            // Strongest first, so the device on the user's body floats to the top.
            self.discovered.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.logger.info("Connected to \(peripheral.identifier.uuidString, privacy: .public)")
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
            self.connectionStates[peripheral.identifier] = .failed(reason)
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
            self.hrvProgress[peripheral.identifier] = nil

            // Rings drop out constantly. Reconnect automatically as long as the source is
            // still enabled; CoreBluetooth will wait for the device to come back.
            guard let source = self.store?.source(id: peripheral.identifier.uuidString),
                  source.isEnabled
            else { return }
            self.connect(peripheral)
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
                    .failed("This device exposes no readable health services.")
                return
            }
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
            guard error == nil, let characteristics = service.characteristics else { return }
            for characteristic in characteristics {
                if GATT.notifyCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.notify)
                       || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if GATT.readOnceCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
            if case .streaming = self.connectionStates[peripheral.identifier] {} else {
                self.connectionStates[peripheral.identifier] = .streaming([])
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value else { return }
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
            case GATT.manufacturerNameString, GATT.modelNumberString:
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
        guard let error else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            self.logger.error(
                "Failed to subscribe to \(uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
