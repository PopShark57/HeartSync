import SwiftUI

/// The iPhone's devices as it last reported them. Read-only: connecting, pausing, renaming,
/// and removing happen on the phone, which owns them.
struct MacDevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.store.sources.isEmpty {
                    EmptyStateView(
                        systemImage: "dot.radiowaves.left.and.right",
                        title: "No devices mirrored",
                        message: "Devices appear here once the iPhone has sent its history."
                    )
                } else {
                    List {
                        ForEach(SourceTransport.allCases, id: \.self) { transport in
                            let sources = model.store.sources.filter { $0.transport == transport }
                            if !sources.isEmpty {
                                Section(transport.title) {
                                    ForEach(sources) { source in
                                        MacDeviceRow(source: source)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationSubtitle("As reported by the iPhone. Change them there.")
            .heartSyncScreenBackground()
        }
    }
}

private struct MacDeviceRow: View {
    @Environment(AppModel.self) private var model
    let source: DataSource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SourceSymbolGlyph(symbol: source.symbol, color: source.color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(SourceLabels.name(for: source.id, in: model.store.sources))
                        .font(.body.weight(.semibold))
                    if !source.isEnabled {
                        Text("Paused")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .heartSyncGlassCapsule(tint: .secondary)
                    }
                }
                if let model = source.model, !model.isEmpty {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(metrics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let seen = source.lastSeenAt {
                    Text("Last reading \(seen.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let percent = source.batteryPercent {
                BatteryBadge(percent: percent, isCharging: source.batteryIsCharging ?? false)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var metrics: String {
        let kinds = MetricKind.allCases.filter { source.observedMetrics.contains($0) }
        guard !kinds.isEmpty else { return String(localized: "No readings yet") }
        return kinds.map(\.title).joined(separator: ", ")
    }
}
