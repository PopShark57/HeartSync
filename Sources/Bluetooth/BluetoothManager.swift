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
