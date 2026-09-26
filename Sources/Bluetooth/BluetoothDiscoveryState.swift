import Foundation

/// Pure GATT discovery/subscription reducer used by `BluetoothManager` and state-machine
/// tests. CoreBluetooth callbacks can arrive in any service order, so readiness is decided
/// only after every requested service and every supported notification subscription has a
/// terminal result.
///
/// Measurement capability and vendor control channels are tracked separately. A candidate
/// with no metrics is a control channel (for example a ring's command channel): subscribing to
/// it proves the channel works, never that a measurement is available, so it can make a
/// connection `.ready` but never adds a metric to the readiness count.
struct BluetoothDiscoveryState: Equatable, Sendable {
    struct Candidate: Equatable, Hashable, Sendable {
        var id: String
        /// Metrics this subscription can deliver. Empty for a control channel.
        var metrics: Set<MetricKind>

        var isControlChannel: Bool { metrics.isEmpty }
    }

    enum Resolution: Equatable, Sendable {
        case discovering
        case enabling(Set<MetricKind>)
        case unsupported(details: [String])
        case subscriptionFailed(details: [String])
        case ready(metrics: Set<MetricKind>, warnings: [String])
    }

    private(set) var pendingServices: Set<String>
    private(set) var pendingSubscriptions: [String: Set<MetricKind>] = [:]
    private(set) var subscribedMetrics: Set<MetricKind> = []
    private(set) var subscribedControlChannels = 0
    private(set) var discoveredCandidateCount = 0
    private(set) var warnings: [String] = []

    init(serviceIDs: Set<String>) {
        pendingServices = serviceIDs
    }

    mutating func finishService(
        id: String,
        candidates: [Candidate],
        errorDescription: String? = nil
    ) {
        guard pendingServices.remove(id) != nil else { return }
        if let errorDescription {
            warnings.append("Service \(id): \(errorDescription)")
        }
        for candidate in candidates {
            discoveredCandidateCount += 1
            pendingSubscriptions[candidate.id] = candidate.metrics
        }
    }

    mutating func finishSubscription(id: String, errorDescription: String? = nil) {
        guard let metrics = pendingSubscriptions.removeValue(forKey: id) else { return }
        if let errorDescription {
            warnings.append("Subscription \(id): \(errorDescription)")
        } else if metrics.isEmpty {
            subscribedControlChannels += 1
        } else {
            subscribedMetrics.formUnion(metrics)
        }
    }

    var resolution: Resolution {
        if !pendingServices.isEmpty { return .discovering }
        let expected = pendingSubscriptions.values.reduce(into: Set<MetricKind>()) {
            $0.formUnion($1)
        }
        if !pendingSubscriptions.isEmpty {
            return .enabling(expected.union(subscribedMetrics))
        }
        if discoveredCandidateCount == 0 {
            return .unsupported(details: warnings)
        }
        if subscribedMetrics.isEmpty, subscribedControlChannels == 0 {
            return .subscriptionFailed(details: warnings)
        }
        return .ready(metrics: subscribedMetrics, warnings: warnings)
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
            kinds.isEmpty
                ? "Enabling notifications\u{2026}"
                : "Enabling \(kinds.count) metric\(kinds.count == 1 ? "" : "s")\u{2026}"
        case .ready(let kinds, let warning):
            // The count is subscription capability, not received values. Heart rate counts
            // once: HRV is derived and appears only after real R\u{2013}R intervals arrive.
            warning ?? (kinds.isEmpty
                ? "Connected; waiting for measurement\u{2026}"
                : "Ready for \(kinds.count) metric\(kinds.count == 1 ? "" : "s"); waiting for data\u{2026}")
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

extension PeripheralConnectionState {
    /// Folds a discovery resolution into the current state without discarding evidence.
    ///
    /// CoreBluetooth can deliver a valid measurement before another service's discovery or
    /// subscription callback finishes. A late callback must not turn observed streaming back
    /// into "enabling" or "ready", so once any metric has been observed on this connection
    /// the measurement evidence governs the state.
    ///
    /// - Parameters:
    ///   - observed: metrics accepted on this connection.
    ///   - onDemandStatus: set when a verified on-demand protocol (a vendor ring session)
    ///     owns measurement. Such a device is not a continuous stream, so it gets no stall
    ///     watchdog and its status comes from the session.
    ///   - adapterWarning: a vendor-session problem to show on an otherwise standard device.
    /// - Returns: the new state, and whether the caller should arm the no-data watchdog.
    static func resolving(
        _ resolution: BluetoothDiscoveryState.Resolution,
        current: Self,
        observed: Set<MetricKind>,
        onDemandStatus: String? = nil,
        adapterWarning: String? = nil
    ) -> (state: Self, armsWatchdog: Bool) {
        if !observed.isEmpty {
            switch current {
            case .streaming, .streamStalled:
                return (current, false)
            default:
                return (.streaming(observed), false)
            }
        }
        switch resolution {
        case .discovering:
            return (.discoveringServices, false)
        case .enabling(let metrics):
            return (.enablingNotifications(metrics), false)
        case .unsupported(let details):
            return (.unsupported(
                details.first ?? "Connected, but no supported measurement characteristic was found. Check that the sensor uses a standard Heart Rate, Pulse Oximeter, or Health Thermometer service."
            ), false)
        case .subscriptionFailed(let details):
            return (.subscriptionFailed(
                details.first ?? "Connected, but measurement notifications could not be enabled. Move the sensor closer and use Reconnect."
            ), false)
        case .ready(let metrics, let warnings):
            if let onDemandStatus {
                return (.ready([], warning: onDemandStatus), false)
            }
            let warning = adapterWarning
                ?? (warnings.isEmpty ? nil : "Ready with a partial service result; waiting for data.")
            return (.ready(metrics, warning: warning), true)
        }
    }
}
