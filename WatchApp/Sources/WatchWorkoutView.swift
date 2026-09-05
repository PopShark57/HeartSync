import SwiftUI

struct WatchWorkoutView: View {
    let workout: WatchWorkoutManager
    @State private var activity = WatchWorkoutActivity.other
    @State private var indoors = false
    @State private var confirmDiscard = false

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
                            Text(activity.rawValue).tag(activity)
                        }
                    }
                    if activity != .other { Toggle("Indoors", isOn: $indoors) }
                    Button {
                        Task { await workout.start(activity: activity, indoors: indoors) }
                    } label: {
                        Label("Start workout", systemImage: "play.fill")
                    }
                    .tint(.green)
                    Text("Records a workout with live heart rate. Wear your watch snugly. Saving adds the workout to Apple Health.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section(workout.activityTitle) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Heart rate", systemImage: "heart.fill").foregroundStyle(.pink)
                            Text(workout.heartRate.map { MetricKind.heartRate.format($0.value) } ?? "—")
                                .font(.system(.largeTitle, design: .rounded).bold())
                                .monospacedDigit()
                            Text("bpm").font(.caption).foregroundStyle(.secondary)
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
