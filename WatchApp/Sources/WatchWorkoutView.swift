import Charts
import SwiftUI

struct WatchWorkoutView: View {
    let workout: WatchWorkoutManager
    @State private var activity = WatchWorkoutActivity.other
    @State private var indoors = false
    /// Off by default: mirroring hands the workout to the paired iPhone, which is a choice.
    @AppStorage("workout.mirrorToPhone") private var mirrorToPhone = false
    @State private var confirmDiscard = false
    /// True in Always On. Heart rate and elapsed time stay prominent; everything secondary
    /// dims, and the trend is hidden, following Apple's Always On guidance.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        List {
            if workout.phase.canStart {
                if workout.phase == .saved { summary }
                if let message = workout.message {
                    Text(message).font(.caption)
                        .foregroundStyle(workout.phase == .failed ? .orange : .secondary)
                }
                Section("Start a workout") {
                    Picker("Activity", selection: $activity) {
                        ForEach(WatchWorkoutActivity.allCases) { activity in
                            Text(activity.title).tag(activity)
                        }
                    }
                    if activity != .other { Toggle("Indoors", isOn: $indoors) }
                    Toggle("Show live on iPhone", isOn: $mirrorToPhone)
                    Button {
                        Task { await workout.start(activity: activity, indoors: indoors, mirrorToPhone: mirrorToPhone) }
                    } label: {
                        Label("Start workout", systemImage: "play.fill")
                    }
                    .tint(.green)
                    Text("Records a workout with live heart rate. Wear your watch snugly. Saving adds the workout to Apple Health.")
                        .font(.caption).foregroundStyle(.secondary)
                    if mirrorToPhone {
                        Text("While HeartSync is open on iPhone, it shows this heart rate beside your other devices. It is not stored there; the workout reaches iPhone through Apple Health.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section(workout.activityTitle) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Heart rate", systemImage: "heart.fill")
                                .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.secondary) : AnyShapeStyle(.pink))
                            Text(workout.heartRate.map { MetricKind.heartRate.format($0.value) } ?? "—")
                                .font(.system(.largeTitle, design: .rounded).bold())
                                .monospacedDigit()
                                // Treated like the complications: redacted when the wearer's
                                // privacy settings hide sensitive data on a lowered wrist,
                                // otherwise kept prominent. See WatchApp/README.md.
                                .privacySensitive()
                            Text("bpm").font(.caption).foregroundStyle(.secondary)
                            if !isLuminanceReduced {
                                WorkoutHeartRateTrendChart(points: workout.heartRateTrend.points(at: timeline.date))
                            }
                            if workout.phase == .paused {
                                Text("Paused · last reading").foregroundStyle(.orange)
                            } else if let reading = workout.heartRate, !reading.isCurrent(at: timeline.date) {
                                Text("Waiting for a new reading").font(.caption).foregroundStyle(.orange)
                            } else if workout.heartRate == nil {
                                Text("Waiting for heart rate. Check watch fit and Heart Rate permission if no reading appears.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Duration.seconds(workout.elapsed(at: timeline.date)), format: .time(pattern: .hourMinuteSecond))
                                .font(.title3).monospacedDigit()
                                .accessibilityLabel("Elapsed time")
                        }
                        .accessibilityElement(children: .combine)
                        .opacity(isLuminanceReduced ? 0.85 : 1)
                    }
                }
                if workout.phase.isCollecting {
                    Button {
                        workout.pauseOrResume()
                    } label: {
                        Label(workout.phase == .paused ? "Resume" : "Pause", systemImage: workout.phase == .paused ? "play.fill" : "pause.fill")
                    }
                    Button("End workout", role: .destructive) { workout.stop() }
                }
                if workout.phase.isBusy {
                    HStack {
                        ProgressView()
                        Text(progressTitle)
                    }
                    .accessibilityElement(children: .combine)
                }
                if workout.phase == .review {
                    summary
                    Button {
                        Task { await workout.save() }
                    } label: {
                        Label("Save to Health", systemImage: "checkmark")
                    }
                    .tint(.green)
                    Button("Discard workout", role: .destructive) { confirmDiscard = true }
                }
                if let message = workout.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Workout")
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { workout.discard() }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("This workout will not be saved. Apple Watch may keep independently collected Health samples.")
        }
    }

    private var summary: some View {
        Section(workout.phase == .saved ? "Workout saved" : "Review workout") {
            Text(Duration.seconds(workout.finalDuration), format: .time(pattern: .hourMinuteSecond))
                .monospacedDigit()
            if let average = workout.averageHeartRate {
                Text("Average: \(MetricKind.heartRate.formatWithUnit(average))")
            } else {
                Text("No heart-rate samples available")
            }
        }
    }

    private var progressTitle: String {
        switch workout.phase {
        case .authorizing: "Health permissions…"
        case .starting: "Starting…"
        case .stopping: "Ending workout…"
        case .saving: "Saving to Health…"
        default: "Working…"
        }
    }
}

/// Five minutes of the workout's heart rate: no axes, broken at gaps, a dot for a lone
/// sample. It is context for the number above, not a measurement of its own, so VoiceOver
/// hears one summary instead of every sample.
private struct WorkoutHeartRateTrendChart: View {
    let points: [WorkoutHeartRateTrend.Point]

    var body: some View {
        if points.count >= 2 {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Heart rate", point.bpm),
                    series: .value("Run", point.segment)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.pink)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 34)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        }
    }

    private var summary: String {
        let values = points.map(\.bpm)
        let low = Int((values.min() ?? 0).rounded())
        let high = Int((values.max() ?? 0).rounded())
        return "Heart rate over the last five minutes, \(low) to \(high) bpm"
    }
}
