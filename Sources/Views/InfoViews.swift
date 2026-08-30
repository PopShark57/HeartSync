import SwiftUI

/// Explains, per metric, which transports can actually supply it. Written because the
/// honest answer differs a lot by metric, and a user comparing devices deserves to know
/// which numbers are measurements and which are not.
struct MetricSourcesView: View {
    var body: some View {
        List {
            ForEach(entries, id: \.kind) { entry in
                Section {
                    ForEach(entry.rows, id: \.transport) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.transport.systemImage)
                                .foregroundStyle(row.available ? row.transport.tint : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.transport.title)
                                    .font(.subheadline.weight(.medium))
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: row.available ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(row.available ? .green : .secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(entry.kind.title, systemImage: entry.kind.systemImage)
                        .foregroundStyle(entry.kind.tint)
                }
            }
        }
        .navigationTitle("Metric Sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Row {
        var transport: SourceTransport
        var available: Bool
        var detail: String
    }

    private struct Entry {
        var kind: MetricKind
        var rows: [Row]
    }

    private var entries: [Entry] {
        [
            Entry(kind: .heartRate, rows: [
                Row(transport: .bluetooth, available: true,
                    detail: "Read live from the standard Heart Rate Measurement characteristic (0x2A37). Updates about once a second."),
                Row(transport: .healthKit, available: true,
                    detail: "Apple Watch samples, delivered through Health. Typically every few minutes at rest, continuously during workouts."),
                Row(transport: .oura, available: true,
                    detail: "Five-minute samples from the Cloud API, available after the ring syncs with the Oura app."),
            ]),
            Entry(kind: .hrvRMSSD, rows: [
                Row(transport: .bluetooth, available: true,
                    detail: "Computed by HeartSync from R\u{2013}R intervals, when the sensor reports them. Chest straps almost always do; optical rings often do not."),
                Row(transport: .healthKit, available: false,
                    detail: "Apple writes SDNN, not RMSSD. It appears under HRV (SDNN) instead \u{2014} the two are different measures and are not compared against each other."),
                Row(transport: .oura, available: true,
                    detail: "Oura's nightly average HRV, which is RMSSD-based."),
            ]),
            Entry(kind: .hrvSDNN, rows: [
                Row(transport: .bluetooth, available: true,
                    detail: "Computed by HeartSync over a five-minute window of R\u{2013}R intervals."),
                Row(transport: .healthKit, available: true,
                    detail: "The Apple Watch's own SDNN, measured during its periodic background readings."),
                Row(transport: .oura, available: false,
                    detail: "Oura does not publish an SDNN figure."),
            ]),
            Entry(kind: .spo2, rows: [
                Row(transport: .bluetooth, available: true,
                    detail: "Read from the Pulse Oximeter Service (0x1822). HeartSync honours the device's own status bits and discards readings it flags as unreliable."),
                Row(transport: .healthKit, available: true,
                    detail: "Apple Watch blood oxygen samples. Note that Health stores these as a fraction; HeartSync converts to whole percent so the scales match."),
                Row(transport: .oura, available: true,
                    detail: "A nightly average rather than a spot reading, so it lines up with other daily figures rather than live ones."),
            ]),
            Entry(kind: .vo2Max, rows: [
                Row(transport: .bluetooth, available: false,
                    detail: "No Bluetooth profile reports VO\u{2082} max. HeartSync can estimate it from resting heart rate, clearly marked as an estimate."),
                Row(transport: .healthKit, available: true,
                    detail: "A real cardio-fitness measurement from the Apple Watch, taken during outdoor walks and runs."),
                Row(transport: .oura, available: true,
                    detail: "Oura's own cardiovascular fitness figure, when your plan includes it."),
            ]),
            Entry(kind: .bloodPressureSystolic, rows: [
                Row(transport: .bluetooth, available: false,
                    detail: "Rings and watches cannot measure blood pressure. A Bluetooth cuff writing to Health does appear here as a real measurement."),
                Row(transport: .healthKit, available: true,
                    detail: "Real cuff readings, from a connected monitor or entered by hand. These are measurements."),
                Row(transport: .manual, available: true,
                    detail: "The HeartSync trend index, if you enable and calibrate it. This is a model, not a measurement, and is excluded from disagreement analysis."),
            ]),
            Entry(kind: .bodyTemperature, rows: [
                Row(transport: .bluetooth, available: true,
                    detail: "Read from the Health Thermometer Service (0x1809) as an absolute temperature."),
                Row(transport: .healthKit, available: true,
                    detail: "Wrist temperature and other body temperature samples written to Health."),
                Row(transport: .oura, available: false,
                    detail: "Oura reports deviation from your personal baseline, not an absolute temperature. HeartSync shows that separately in the Oura tab and never compares it with thermometer readings."),
            ]),
        ]
    }
}

/// The plain statement of what this app can and cannot do.
struct DisclaimerView: View {
    var body: some View {
        List {
            Section {
                Text("HeartSync is not a medical device. It reads consumer wearables and shows you what they say. Nothing here is a diagnosis, and none of it should be used to make a medical decision. If a reading worries you, talk to a clinician.")
                    .font(.subheadline)
            }

            Section("Blood pressure") {
                Text("Optical sensors in rings and watches cannot measure blood pressure. Methods that estimate it from pulse transit time need two synchronised sensors and per-person calibration, and single-sensor approaches have not been shown to track absolute pressure in everyday use.")
                    .font(.subheadline)
                Text("The blood pressure index in this app is a trend indicator anchored to a cuff reading you enter, clamped to a narrow band, and shown with a wide interval. It will not detect hypertension and will not tell you your blood pressure has changed. Use a validated cuff.")
                    .font(.subheadline)
            }

            Section("Why devices disagree") {
                bullet("Different sensors. An ECG chest strap measures electrical activity; a ring measures light absorption. They are not measuring the same thing, and their HRV figures are not interchangeable.")
                bullet("Different windows. One device may average over five minutes and another over thirty seconds. HeartSync buckets everything onto a shared grid to reduce this, but it cannot undo the averaging a device did before reporting.")
                bullet("Different artefact handling. Every vendor throws away suspect beats differently, and none of them publish exactly how.")
                bullet("Motion. Optical sensors degrade quickly with movement. A disagreement while you are walking usually means the optical device is wrong, not the strap.")
                bullet("Placement. A loose ring or a dry strap will read badly. Check fit before trusting a discrepancy.")
            }

            Section("What the numbers mean") {
                bullet("Mean bias is the average signed difference. A consistent sign means one device really does read higher.")
                bullet("Limits of agreement span the range containing 95% of the differences. Two devices are interchangeable only if that whole range is narrow enough for your purposes.")
                bullet("HeartSync uses the median within each window, not the mean, so one motion spike cannot manufacture a discrepancy.")
            }

            Section("Your data") {
                Text("Everything stays on this device. There is no HeartSync account or server. Oura sign-in opens cloud.ouraring.com, and read-only data requests go to api.ouraring.com using the OAuth access token kept in this device's Keychain.")
                    .font(.subheadline)
            }
        }
        .navigationTitle("Limitations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}").foregroundStyle(.secondary)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}
