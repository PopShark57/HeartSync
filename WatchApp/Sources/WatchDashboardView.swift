import SwiftUI

struct WatchDashboardView: View {
    let connection: CompanionSession
    var openWorkout: () -> Void

    var body: some View {
        List {
            Button(action: openWorkout) {
                Label("Workout", systemImage: "figure.run")
            }
            .accessibilityHint("Open live heart-rate workout controls")

            if let snapshot = connection.snapshot {
                Section {
                    if snapshot.availability == .unavailable {
                        Label("iPhone data unavailable", systemImage: "lock.iphone")
                        Text("Unlock your iPhone and open HeartSync, then refresh.")
                            .font(.caption)
                    } else if snapshot.metrics.isEmpty {
                        Label("No readings yet", systemImage: "heart.text.square")
                        Text("Connect Apple Health or a sensor in HeartSync on iPhone.")
                            .font(.caption)
                    } else {
                        ForEach(snapshot.metrics) { metric in
                            NavigationLink {
                                WatchMetricDetailView(metric: metric, generatedAt: snapshot.generatedAt)
                            } label: {
                                WatchMetricRow(metric: metric)
                            }
                        }
                    }
                } header: {
                    Text("From iPhone")
                } footer: {
                    VStack(alignment: .leading) {
                        Text("Snapshot updated")
                        Text(snapshot.generatedAt, style: .relative)
                        Text("Readings have their own timestamps.")
                    }
                }
            } else {
                Section("From iPhone") {
                    Label("Welcome to HeartSync", systemImage: "heart.fill")
                    Text("Open HeartSync on your paired iPhone to receive your latest readings. You can start a workout on this watch independently.")
                        .font(.caption)
                }
            }

            Section {
                Button {
                    connection.requestRefresh()
                } label: {
                    Label(connection.isRequesting ? "Requesting…" : "Refresh iPhone data", systemImage: "arrow.clockwise")
                }
                .disabled(connection.isRequesting || !connection.isReachable)
                Text(connection.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("HeartSync")
    }
}

private struct WatchMetricRow: View {
    let metric: WatchMetric

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                Label(metric.kind.title, systemImage: metric.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(metric.kind.tint)
                if let reading = metric.readings.first {
                    Text(metric.kind.formatWithUnit(reading.value))
                        .font(.title3.bold()).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                    Text(reading.sourceName).font(.caption2).lineLimit(2)
                    HStack {
                        Text(reading.provenance.title)
                        if reading.isStale(kind: metric.kind, now: timeline.date) {
                            Text("Older reading").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct WatchMetricDetailView: View {
    let metric: WatchMetric
    let generatedAt: Date

    var body: some View {
        List {
            ForEach(metric.readings) { reading in
                Section(reading.sourceName) {
                    Text(metric.kind.formatWithUnit(reading.value))
                        .font(.title2.bold()).monospacedDigit()
                    Label(reading.provenance.title, systemImage: reading.provenance.systemImage)
                        .font(.caption)
                    Text(reading.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                    if reading.isCompacted {
                        Text("Compacted window median").font(.caption).foregroundStyle(.secondary)
                    }
                    if reading.provenance == .estimated {
                        Text("Modelled estimate, not a measurement. Never use this value for medical decisions or device agreement.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if metric.omittedSourceCount > 0 {
                Text("\(metric.omittedSourceCount) more sources on iPhone. Comparison includes all enabled sources.")
                    .font(.caption)
            }
            Section("Comparison at sync") {
                let comparison = metric.comparison
                if comparison.outsideTolerancePairs > 0 {
                    Label("\(comparison.outsideTolerancePairs) pairs outside tolerance", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if comparison.allPairsAgree {
                    Label("Within tolerance", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Insufficient evidence", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                Text("\(comparison.readyPairs) ready · \(comparison.incompletePairs) incomplete")
                    .font(.caption)
                Text(comparison.lookback >= 86_400 ? "Past 7 days" : "Past hour")
                    .font(.caption)
                Text(generatedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                Text("At least five paired windows are needed. Estimates are excluded. Agreement does not establish medical accuracy. Full analysis is on iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(metric.kind.shortTitle)
    }
}
