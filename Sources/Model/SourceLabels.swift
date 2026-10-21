import Foundation

/// One presentation policy for legends, rows, pair names and spoken labels. Stable IDs
/// remain identity; labels add detail only when visible names collide.
enum SourceLabels {
    static func make(for sources: [DataSource]) -> [String: String] {
        let names = Dictionary(grouping: sources, by: \.displayName)
        var labels: [String: String] = [:]
        for source in sources {
            let peers = names[source.displayName] ?? []
            let transportPeers = peers.filter { $0.transport == source.transport }
            if peers.count == 1 { labels[source.id] = source.displayName }
            else if transportPeers.count == 1 { labels[source.id] = "\(source.displayName) (\(source.transport.title))" }
            else if let model = source.model, !model.isEmpty,
                    transportPeers.count(where: { $0.model == model }) == 1 {
                labels[source.id] = "\(source.displayName) (\(source.transport.title), \(model))"
            } else {
                // Stable hashed IDs also work for non-UUID source IDs; extend on collision.
                let token = (UUID(uuidString: source.id) ?? UUID(stableFrom: source.id)).uuidString
                let peers = transportPeers.map { (UUID(uuidString: $0.id) ?? UUID(stableFrom: $0.id)).uuidString }
                var length = 6
                while length < token.count, peers.filter({ $0.suffix(length) == token.suffix(length) }).count > 1 { length += 1 }
                labels[source.id] = "\(source.displayName) (\(source.transport.title), \(token.suffix(length)))"
            }
        }
        return labels
    }

    static func name(for id: String, in sources: [DataSource]) -> String {
        make(for: sources)[id] ?? "Unknown device"
    }
    /// Bounded payload labels retain an identifier even when a long name hides qualifiers.
    static func boundedName(for id: String, in sources: [DataSource], maximumLength: Int = 100) -> String {
        let labels = make(for: sources)
        let label = labels[id] ?? "Unknown device"
        guard label.count > maximumLength else { return label }
        let token = (UUID(uuidString: id) ?? UUID(stableFrom: id)).uuidString
        let suffix = "… [\(token.suffix(12))]"
        return String(label.prefix(max(0, maximumLength - suffix.count))) + suffix
    }

}
