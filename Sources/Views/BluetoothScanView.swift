import SwiftUI

/// Live scan sheet for adding a Bluetooth sensor.
struct BluetoothScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !model.bluetooth.isPoweredOn {
                    Section {
                        Label(model.bluetooth.stateDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                            .accessibilityLabel("Bluetooth unavailable. \(model.bluetooth.stateDescription)")
                    }
                }

                Section {
                    if candidates.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.bluetooth.isScanning ? "Scanning\u{2026}" : "Not scanning")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.bluetooth.isScanning
                            ? "Scanning for nearby sensors. Nothing found yet."
                            : "Not scanning. No devices found.")
                    } else {
                        ForEach(candidates) { peripheral in
                            Button {
                                model.bluetooth.add(peripheral)
                                dismiss()
                            } label: {
                                DiscoveredRow(peripheral: peripheral)
                            }
                            .disabled(!peripheral.isConnectable)
                            .accessibilityHint(peripheral.isConnectable
                                ? "Adds this sensor to your devices and connects to it"
                                : "This device is not accepting connections")
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby")
                        Spacer()
                        // Decorative duplicate of the toolbar's Stop/Scan state.
                        if model.bluetooth.isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        }
                    }
                } footer: {
                    Text("Put your sensor into pairing mode and make sure it is on your body \u{2014} many rings and straps only advertise once they detect skin contact.")
                }

                Section {
                    Toggle("Show all Bluetooth devices", isOn: showAllBinding)
                } footer: {
                    Text("By default only devices advertising a heart-rate, pulse-oximeter, or thermometer service are listed. Some inexpensive rings omit those from their advertisement and only reveal them after connecting \u{2014} turn this on to find them, at the cost of a much noisier list.")
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.bluetooth.isScanning ? "Stop" : "Scan") {
                        if model.bluetooth.isScanning {
                            model.bluetooth.stopScan()
                        } else {
                            model.bluetooth.startScan()
                        }
                    }
                    .disabled(!model.bluetooth.isPoweredOn)
                    .accessibilityHint(model.bluetooth.isScanning
                        ? "Stops the Bluetooth scan"
                        : "Starts a Bluetooth scan, which stops on its own after a minute")
                }
            }
            .onAppear { model.bluetooth.startScan() }
            .onDisappear { model.bluetooth.stopScan() }
        }
    }

    private var showAllBinding: Binding<Bool> {
        Binding(
            get: { model.bluetooth.scanForAllDevices },
            set: { newValue in
                model.bluetooth.scanForAllDevices = newValue
                // Restart so the new filter takes effect immediately.
                if model.bluetooth.isScanning {
                    model.bluetooth.stopScan()
                    model.bluetooth.startScan()
                }
            }
        )
    }

    /// Hides devices already added, and stale entries that have not been seen recently.
    private var candidates: [DiscoveredPeripheral] {
        let existing = Set(model.store.sources.map(\.id))
        let cutoff = Date.now.addingTimeInterval(-15)
        return model.bluetooth.discovered.filter { peripheral in
            !existing.contains(peripheral.id.uuidString) && peripheral.lastSeen >= cutoff
        }
    }
}

private struct DiscoveredRow: View {
    var peripheral: DiscoveredPeripheral

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(peripheral.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            SignalBars(bars: peripheral.signalBars)
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Advertised services, or why we cannot say what this device offers yet.
    private var detailText: String {
        guard peripheral.advertisedServices.isEmpty else {
            return peripheral.advertisedServices.joined(separator: " \u{00B7} ")
        }
        return peripheral.isConnectable ? "Services unknown until connected" : "Not connectable"
    }

    /// One VoiceOver element per scan result.
    ///
    /// The row's icons are decorative — the sensor glyph is the same on every row and the
    /// plus glyph duplicates what tapping the row already does — while signal strength is
    /// drawn as bars, which carry no text at all. Children are ignored so the composed
    /// sentence can state the name, what the device advertises, and the signal in words.
    private var accessibilityDescription: String {
        [peripheral.name, detailText, "Signal strength \(peripheral.signalBars) of 3"]
            .joined(separator: ". ")
    }
}
