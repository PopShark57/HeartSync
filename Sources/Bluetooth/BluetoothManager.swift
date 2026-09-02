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
        case .discoveringServices:
            String(localized: "peripheral.state.discoveringServices", defaultValue: "Reading services\u{2026}", comment: "Bluetooth device status: discovering GATT services after connecting")
        case .streaming(let kinds):
            if kinds.isEmpty {
                String(localized: "peripheral.state.connected", defaultValue: "Connected", comment: "Bluetooth device status: connected but not yet receiving any metric")
            } else if kinds.count == 1 {
                String(localized: "peripheral.state.streaming.one", defaultValue: "Streaming 1 metric", comment: "Bluetooth device status: receiving exactly one metric")
            } else {
                String(localized: "peripheral.state.streaming.many", defaultValue: "Streaming \(kinds.count) metrics", comment: "Bluetooth device status: receiving several metrics. The number is always 2 or more.")
            }
        case .failed(let reason):
            reason
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

    let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Bluetooth")

    // MARK: Observable state

    // Writable from BluetoothManager+Delegates (same-module extension).
    var state: CBManagerState = .unknown
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredPeripheral] = []
    var connectionStates: [UUID: PeripheralConnectionState] = [:]
    /// Live per-device HRV buffer progress, so the UI can show "collecting beats" rather
    /// than an empty HRV tile for the first few minutes.
    var hrvProgress: [UUID: (beats: Int, seconds: TimeInterval)] = [:]
    /// Quality of the most recently emitted HRV window per device.
    ///
    /// Keyed by `CBPeripheral.identifier`, which is the same UUID the source ID is built
    /// from. Replaced on every emission and cleared on disconnect/forget, because this
    /// describes one live window and a stale entry would caveat the wrong data.
    var hrvQuality: [UUID: HRVQuality] = [:]

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
    var peripherals: [UUID: CBPeripheral] = [:]
    var hrvAccumulators: [UUID: HRVAccumulator] = [:]
    var pendingModelInfo: [UUID: DeviceInformation] = [:]
    private var scanTimeoutTask: Task<Void, Never>?

    /// Scan results as they arrive, before publication.
    ///
    /// The scan allows duplicates, so a busy room delivers advertisement packets far
    /// faster than any list needs to change. Packets land here; `publishDiscovered()`
    /// sorts and copies them into the observable `discovered` at `discoveryPublishInterval`
    /// so SwiftUI is invalidated a few times a second instead of a few hundred.
    var discoveredByID: [UUID: DiscoveredPeripheral] = [:]
    var hasUnpublishedDiscoveries = false
    private var discoveryPublishTask: Task<Void, Never>?

    /// Publication cadence for scan results. 400 ms (2.5 Hz) is well inside the ~100 ms
    /// at which a list stops looking responsive, and far below the packet rate.
    private static let discoveryPublishInterval: Duration = .milliseconds(400)

    /// Reconnection attempts since the last successful connection, per peripheral.
    var reconnectAttempts: [UUID: Int] = [:]
    var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    /// Reconnection backoff. A ring that connects and drops repeatedly would otherwise
    /// spin a tight connect loop forever; these bound it and give the user a state to
    /// retry from instead of an invisible failure.
    private static let firstReconnectDelay: TimeInterval = 1
    private static let maximumReconnectDelay: TimeInterval = 60
    private static let maximumReconnectAttempts = 6

    weak var store: HealthStore?
    var onReading: (@MainActor (Reading) -> Void)?

    /// Device Information Service strings, accumulated as the individual characteristics
    /// arrive. They are read separately and in no guaranteed order, so the display string
    /// is rebuilt from whatever is known each time one lands.
    struct DeviceInformation {
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

    func connect(_ peripheral: CBPeripheral) {
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
        hrvProgress[uuid] = nil
        hrvQuality[uuid] = nil
        pendingModelInfo[uuid] = nil
        reconnectAttempts[uuid] = nil
        // `discoveredByID` is deliberately left alone: a forgotten device should still be
        // offered by an in-flight scan so the user can add it back.
    }

    func cancelPendingReconnect(for id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
    }

    /// Schedules a reconnection attempt after an exponentially growing delay.
    ///
    /// Shared by the disconnect and fail-to-connect paths. Gives up after
    /// `maximumReconnectAttempts` and leaves the device in `.failed`, which is a state the
    /// user can act on from the devices list \u{2014} a silent retry loop is not.
    func scheduleReconnect(
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

    func discoverServices(on peripheral: CBPeripheral) {
        connectionStates[peripheral.identifier] = .discoveringServices
        peripheral.delegate = self
        // Pass an explicit list rather than nil: discovering every service on a chatty
        // device costs seconds and yields nothing this app can read.
        peripheral.discoverServices(GATT.discoverServices)
    }
}
