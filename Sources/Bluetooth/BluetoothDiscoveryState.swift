import Foundation

/// Pure GATT discovery/subscription reducer used by `BluetoothManager` and state-machine
/// tests. CoreBluetooth callbacks can arrive in any service order, so readiness is decided
/// only after every requested service and every supported notification subscription has a
/// terminal result.
struct BluetoothDiscoveryState: Equatable, Sendable {
    struct Candidate: Equatable, Hashable, Sendable {
        var id: String
        var metrics: Set<MetricKind>
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
        if subscribedMetrics.isEmpty {
            return .subscriptionFailed(details: warnings)
        }
        return .ready(metrics: subscribedMetrics, warnings: warnings)
    }
}
