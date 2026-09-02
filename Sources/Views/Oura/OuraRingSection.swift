import SwiftUI

/// Battery and hardware details as last reported by the Oura cloud.
///
/// The battery figure is the newest cached reading, not a live query of the ring, so it can
/// lag until the Oura app syncs.
struct OuraRingSection: View {
    var battery: OuraClient.RingBatteryLevel?
    var ring: OuraClient.RingConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Ring",
                subtitle: "Battery and hardware reported by Oura",
                systemImage: "circle.circle"
            )

            VStack(alignment: .leading, spacing: 16) {
                if let battery {
                    HStack(spacing: 12) {
                        Image(systemName: OuraFormat.batteryIcon(for: battery.level))
                            .font(.title2)
                            .foregroundStyle(battery.level <= 15 ? .red : .green)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Battery")
                                    .font(.headline)
                                Spacer()
                                Text("\(battery.level)%")
                                    .font(.headline.monospacedDigit())
                            }
                            ProgressView(value: Double(battery.level), total: 100)
                                .tint(battery.level <= 15 ? .red : .green)
                        }
                    }
                    if battery.charging == true || battery.in_charger == true {
                        Label(battery.charging == true ? "Charging" : "In charger", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if battery != nil, ring != nil { Divider() }

                if let ring {
                    LazyVGrid(columns: OuraCardLayout.metricColumns, alignment: .leading, spacing: 12) {
                        OuraMiniStat(title: "Generation", value: OuraFormat.pretty(ring.hardware_type) ?? "—")
                        OuraMiniStat(title: "Design", value: OuraFormat.pretty(ring.design) ?? "—")
                        OuraMiniStat(title: "Color", value: OuraFormat.pretty(ring.color) ?? "—")
                        OuraMiniStat(title: "Size", value: ring.size.map(String.init) ?? "—")
                        OuraMiniStat(title: "Firmware", value: ring.firmware_version ?? "—")
                        OuraMiniStat(title: "Set up", value: OuraFormat.dateTimeLabel(ring.set_up_at))
                    }
                }

                if battery == nil, ring == nil {
                    OuraInlineEmptyState(icon: "battery.0percent", text: "No ring battery or configuration record is available.")
                }
            }
            .ouraCard()
        }
    }
}
