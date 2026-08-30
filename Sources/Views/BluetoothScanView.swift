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
                    } else {
                        ForEach(candidates) { peripheral in
                            Button {
                                model.bluetooth.add(peripheral)
                                dismiss()
                            } label: {
                                DiscoveredRow(peripheral: peripheral)
                            }
                            .disabled(!peripheral.isConnectable)
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby")
                        Spacer()
                        if model.bluetooth.isScanning { ProgressView().controlSize(.mini) }
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
                if peripheral.advertisedServices.isEmpty {
                    Text(peripheral.isConnectable ? "Services unknown until connected" : "Not connectable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(peripheral.advertisedServices.joined(separator: " \u{00B7} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            SignalBars(bars: peripheral.signalBars)
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}
