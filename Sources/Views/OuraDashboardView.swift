import Charts
import SwiftUI

/// A ring-first view of everything Oura has most recently processed and uploaded.
///
/// Oura is a cloud source, not a live Bluetooth stream. Cached records therefore stay on
/// screen through partial endpoint failures and every freshness label refers to the cloud
/// sync, never to a live sensor connection.
struct OuraDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSetup = false

    private let cardColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let metricColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if !model.oura.hasAuthorization && !model.oura.snapshot.hasData {
                    disconnectedView
                } else {
                    dashboard
                }
            }
            .navigationTitle("Oura")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.oura.isSyncing {
                        ProgressView()
                            .accessibilityLabel("Syncing Oura data")
                    } else if model.oura.hasAuthorization {
                        Button {
                            Task { await model.oura.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Sync Oura now")
                    }
                }
            }
            .sheet(isPresented: $showingSetup) {
                OuraSetupView()
            }
        }
    }

    // MARK: - Page states

    private var disconnectedView: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.indigo.opacity(0.22), .purple.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 112, height: 112)
                        Image(systemName: "circle.circle.fill")
                            .font(.system(size: 50, weight: .medium))
                            .foregroundStyle(.indigo)
                    }

                    Text("Your Oura data, in one place")
                        .font(.title2.bold())
                    Text("Connect with OAuth to explore sleep, readiness, activity, recovery, heart signals, movement patterns, workouts, sessions, and ring details.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                    Button {
                        showingSetup = true
                    } label: {
                        Label("Connect Oura", systemImage: "link")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 26)

                VStack(alignment: .leading, spacing: 12) {
                    HonestInfoRow(
                        icon: "lock.shield.fill",
                        tint: .green,
                        title: "Private by design",
                        message: "Your OAuth token stays in this device's Keychain. Imported Oura records are cached locally."
                    )
                    HonestInfoRow(
                        icon: "icloud.and.arrow.down",
                        tint: .blue,
                        title: "Latest Oura cloud data",
                        message: "The ring uploads through the Oura app. Sleep and readiness can lag until that sync finishes."
                    )
                    HonestInfoRow(
                        icon: "waveform.path",
                        tint: .orange,
                        title: "Processed movement, not raw accelerometer",
                        message: "Oura's public API exposes movement classes, MET samples, and session motion counts—not the ring's raw accelerometer stream."
                    )
                }
                .ouraCard()
            }
            .padding()
            .padding(.bottom, 24)
        }
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                connectionHeader

                if model.oura.snapshot.hasData {
                    scoresSection
                    biomarkersSection
                    heartRateSection
                    sleepSection
                    movementSection
                    timelineSection
                    ringSection
                } else {
                    waitingForDataCard
                }

                if !model.oura.endpointIssues.isEmpty {
                    endpointIssuesSection
                }

                oauthSection
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .refreshable {
            guard model.oura.hasAuthorization else { return }
            await model.oura.sync()
        }
    }

    private var waitingForDataCard: some View {
        VStack(spacing: 12) {
            if model.oura.isSyncing {
                ProgressView()
                    .controlSize(.large)
                Text("Fetching recent Oura history…")
                    .font(.headline)
                Text("Each collection is imported independently, so available cards will remain even if another permission is missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No Oura data yet")
                    .font(.headline)
                Text("Open the Oura app to sync your ring, then refresh here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.oura.hasAuthorization {
                    Button("Sync now") {
                        Task { await model.oura.sync() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .ouraCard()
    }

    // MARK: - Connection

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.20))
                        .frame(width: 48, height: 48)
                    Image(systemName: "circle.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.oura.hasAuthorization ? "Latest Oura cloud data" : "Cached Oura data")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    if model.oura.hasAuthorization {
                        Task { await model.oura.sync() }
                    } else {
                        showingSetup = true
                    }
                } label: {
                    if model.oura.isSyncing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: model.oura.hasAuthorization ? "arrow.clockwise" : "link")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(model.oura.isSyncing)
                .accessibilityLabel(model.oura.hasAuthorization ? "Sync Oura now" : "Reconnect Oura")
            }

            HStack(spacing: 10) {
                if let battery = model.oura.snapshot.latestBatteryLevel {
                    HeaderPill(
                        icon: batteryIcon(for: battery.level),
                        text: "\(battery.level)%",
                        tint: battery.level <= 15 ? .red : .white
                    )
                }
                HeaderPill(
                    icon: model.oura.endpointIssues.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    text: model.oura.endpointIssues.isEmpty
                        ? "Collections current"
                        : "\(model.oura.endpointIssues.count) unavailable",
                    tint: model.oura.endpointIssues.isEmpty ? .white : .yellow
                )
                if model.oura.snapshot.totalRecordCount > 0 {
                    HeaderPill(
                        icon: "tray.full.fill",
                        text: "\(model.oura.snapshot.totalRecordCount) cached",
                        tint: .white
                    )
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [.indigo, .purple.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .padding(.top, 4)
    }

    private var connectionSubtitle: String {
        if case .error(let message) = model.oura.status { return message }
        if let last = model.oura.lastSyncedAt {
            return "Cloud sync \(last.formatted(.relative(presentation: .named)))"
        }
        return model.oura.hasAuthorization ? "Connected · waiting for the first sync" : "Authorization required to refresh"
    }

    // MARK: - Scores

    private var scoresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Today's signals",
                subtitle: "Oura scores and recovery context",
                systemImage: "sparkles"
            )

            LazyVGrid(columns: cardColumns, spacing: 12) {
                ScoreCard(
                    title: "Activity",
                    value: model.oura.snapshot.latestActivity?.score.map(String.init) ?? "—",
                    progress: model.oura.snapshot.latestActivity?.score.map { Double($0) / 100 },
                    detail: dayLabel(model.oura.snapshot.latestActivity?.day),
                    icon: "figure.walk",
                    tint: .orange
                )
                ScoreCard(
                    title: "Readiness",
                    value: model.oura.snapshot.latestReadiness?.score.map(String.init) ?? "—",
                    progress: model.oura.snapshot.latestReadiness?.score.map { Double($0) / 100 },
                    detail: dayLabel(model.oura.snapshot.latestReadiness?.day),
                    icon: "bolt.heart.fill",
                    tint: .green
                )
                ScoreCard(
                    title: "Sleep",
                    value: model.oura.snapshot.latestSleepScore?.score.map(String.init) ?? "—",
                    progress: model.oura.snapshot.latestSleepScore?.score.map { Double($0) / 100 },
                    detail: dayLabel(model.oura.snapshot.latestSleepScore?.day),
                    icon: "moon.stars.fill",
                    tint: .indigo
                )
                ScoreCard(
                    title: "Resilience",
                    value: pretty(model.oura.snapshot.latestResilience?.level) ?? "—",
                    progress: resilienceProgress(model.oura.snapshot.latestResilience?.level),
                    detail: dayLabel(model.oura.snapshot.latestResilience?.day),
                    icon: "shield.lefthalf.filled",
                    tint: .purple
                )
                ScoreCard(
                    title: "Stress",
                    value: pretty(model.oura.snapshot.latestStress?.day_summary) ?? "—",
                    progress: nil,
                    detail: stressDetail,
                    icon: "brain.head.profile",
                    tint: .pink
                )
            }
        }
    }

    private var stressDetail: String {
        guard let stress = model.oura.snapshot.latestStress else { return "No daily summary" }
        let stressTime = durationText(stress.stress_high)
        let recoveryTime = durationText(stress.recovery_high)
        if let stressTime, let recoveryTime { return "\(stressTime) stress · \(recoveryTime) recovery" }
        return dayLabel(stress.day)
    }

    // MARK: - Biomarkers

    private var biomarkersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Biomarkers",
                subtitle: "Latest values processed by Oura",
                systemImage: "waveform.path.ecg"
            )

            LazyVGrid(columns: metricColumns, spacing: 12) {
                ForEach(biomarkers) { item in
                    BiomarkerCard(item: item)
                }
            }
        }
    }

    private var biomarkers: [BiomarkerItem] {
        let snapshot = model.oura.snapshot
        let sleep = snapshot.latestSleep
        let readiness = snapshot.latestReadiness
        let oxygen = snapshot.latestOxygen
        let cardio = snapshot.latestCardiovascularAge

        return [
            BiomarkerItem(
                id: "heart-rate",
                title: "Heart rate",
                value: snapshot.latestHeartRate.map { String($0.bpm) } ?? "—",
                unit: "bpm",
                detail: pretty(snapshot.latestHeartRate?.source) ?? "Latest sample",
                icon: "heart.fill",
                tint: .pink
            ),
            BiomarkerItem(
                id: "resting-heart-rate",
                title: "Resting HR",
                value: number(sleep?.lowest_heart_rate, digits: 0),
                unit: "bpm",
                detail: "Nightly low",
                icon: "heart.circle.fill",
                tint: .red
            ),
            BiomarkerItem(
                id: "hrv",
                title: "HRV (RMSSD)",
                value: number(sleep?.average_hrv, digits: 0),
                unit: "ms",
                detail: "Nightly average",
                icon: "waveform.path.ecg",
                tint: .purple
            ),
            BiomarkerItem(
                id: "respiration",
                title: "Respiration",
                value: number(sleep?.average_breath, digits: 1),
                unit: "br/min",
                detail: "During sleep",
                icon: "wind",
                tint: .teal
            ),
            BiomarkerItem(
                id: "oxygen",
                title: "Blood oxygen",
                value: number(oxygen?.spo2_percentage?.average, digits: 1),
                unit: "%",
                detail: "Sleep average",
                icon: "lungs.fill",
                tint: .blue
            ),
            BiomarkerItem(
                id: "bdi",
                title: "Breathing disturbances",
                value: oxygen?.breathing_disturbance_index.map(String.init) ?? "—",
                unit: "index",
                detail: "Detected SpO₂ drops",
                icon: "waveform.badge.magnifyingglass",
                tint: .cyan
            ),
            BiomarkerItem(
                id: "temperature",
                title: "Temperature deviation",
                value: signed(readiness?.temperature_deviation, digits: 1),
                unit: "°C",
                detail: "From your Oura baseline",
                icon: "thermometer.medium",
                tint: .orange
            ),
            BiomarkerItem(
                id: "vo2-max",
                title: "VO₂ max",
                value: number(snapshot.latestVO2Max?.vo2_max, digits: 1),
                unit: "mL/kg·min",
                detail: dayLabel(snapshot.latestVO2Max?.day),
                icon: "figure.run",
                tint: .green
            ),
            BiomarkerItem(
                id: "vascular-age",
                title: "Vascular age",
                value: cardio?.vascular_age.map(String.init) ?? "—",
                unit: "years",
                detail: dayLabel(cardio?.day),
                icon: "calendar.badge.clock",
                tint: .mint
            ),
            BiomarkerItem(
                id: "pulse-wave",
                title: "Pulse wave velocity",
                value: number(cardio?.pulse_wave_velocity, digits: 1),
                unit: "m/s",
                detail: "Oura cardiovascular estimate",
                icon: "waveform.path",
                tint: .indigo
            ),
        ]
    }

    // MARK: - Heart-rate chart

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Heart rate",
                subtitle: "Recent Oura cloud samples",
                systemImage: "chart.xyaxis.line"
            )

            VStack(alignment: .leading, spacing: 12) {
                if heartChartPoints.isEmpty {
                    InlineEmptyState(icon: "heart.slash", text: "No heart-rate samples in the current Oura cache.")
                } else {
                    Chart(heartChartPoints) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Baseline", heartChartFloor),
                            yEnd: .value("Heart rate", point.bpm)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.pink.opacity(0.24), .pink.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Heart rate", point.bpm)
                        )
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .frame(height: 210)

                    HStack {
                        if let low = heartChartPoints.map(\.bpm).min(),
                           let high = heartChartPoints.map(\.bpm).max() {
                            Label("\(Int(low))–\(Int(high)) bpm", systemImage: "arrow.up.arrow.down")
                        }
                        Spacer()
                        Text("Last 24 hours in cache")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .ouraCard()
        }
    }

    private var heartChartPoints: [HeartChartPoint] {
        let all = model.oura.snapshot.heartRates.compactMap { point -> HeartChartPoint? in
            guard let date = OuraClient.parseTimestamp(point.timestamp) else { return nil }
            return HeartChartPoint(id: "\(point.timestamp)-\(point.bpm)", date: date, bpm: Double(point.bpm))
        }
        .sorted { $0.date < $1.date }
        guard let newest = all.last?.date else { return [] }
        let cutoff = newest.addingTimeInterval(-86_400)
        return all.filter { $0.date >= cutoff }
    }

    private var heartChartFloor: Double {
        max(0, (heartChartPoints.map(\.bpm).min() ?? 40) - 8)
    }

    // MARK: - Sleep

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Sleep",
                subtitle: "Stages and overnight recovery",
                systemImage: "bed.double.fill"
            )

            VStack(alignment: .leading, spacing: 16) {
                if let sleep = model.oura.snapshot.latestSleep {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(durationText(sleep.total_sleep_duration) ?? "—")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("total sleep · \(dayLabel(sleep.day))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let efficiency = sleep.efficiency {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(efficiency)%")
                                    .font(.title2.bold().monospacedDigit())
                                Text("efficiency")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let phases = sleep.sleep_phase_5_min, !phases.isEmpty {
                        CategoricalRibbon(
                            values: Array(phases),
                            colors: sleepStageColors,
                            fallback: .gray.opacity(0.25),
                            accessibilityText: "Sleep-stage timeline with \(phases.count) five-minute intervals"
                        )
                        .frame(height: 28)

                        RibbonLegend(items: [
                            ("Deep", sleepStageColors["1"]!),
                            ("Light", sleepStageColors["2"]!),
                            ("REM", sleepStageColors["3"]!),
                            ("Awake", sleepStageColors["4"]!),
                        ])
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                        MiniStat(title: "Deep", value: durationText(sleep.deep_sleep_duration) ?? "—")
                        MiniStat(title: "REM", value: durationText(sleep.rem_sleep_duration) ?? "—")
                        MiniStat(title: "Light", value: durationText(sleep.light_sleep_duration) ?? "—")
                        MiniStat(title: "Awake", value: durationText(sleep.awake_time) ?? "—")
                        MiniStat(title: "Time in bed", value: durationText(sleep.time_in_bed) ?? "—")
                        MiniStat(title: "Latency", value: durationText(sleep.latency) ?? "—")
                        MiniStat(title: "Restless periods", value: sleep.restless_periods.map(String.init) ?? "—")
                        MiniStat(title: "Bedtime", value: bedtimeText(sleep.bedtime_start))
                    }
                } else {
                    InlineEmptyState(icon: "moon.zzz", text: "No detailed sleep record is available yet.")
                }
            }
            .ouraCard()
        }
    }

    private let sleepStageColors: [Character: Color] = [
        "1": .indigo,
        "2": .blue.opacity(0.68),
        "3": .purple,
        "4": .orange,
    ]

    // MARK: - Movement and activity

    private var movementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Movement & activity",
                subtitle: "Processed movement from the Oura cloud",
                systemImage: "figure.walk.motion"
            )

            VStack(alignment: .leading, spacing: 16) {
                if let activity = model.oura.snapshot.latestActivity {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.steps.formatted())
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("steps · \(dayLabel(activity.day))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(activity.active_calories) kcal")
                                .font(.title3.bold().monospacedDigit())
                            Text("active energy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let classes = activity.class_5_min, !classes.isEmpty {
                        CategoricalRibbon(
                            values: Array(classes),
                            colors: movementColors,
                            fallback: .gray.opacity(0.2),
                            accessibilityText: "Processed daily movement timeline with \(classes.count) five-minute intervals"
                        )
                        .frame(height: 28)

                        RibbonLegend(items: [
                            ("Rest", movementColors["1"]!),
                            ("Inactive", movementColors["2"]!),
                            ("Low", movementColors["3"]!),
                            ("Medium", movementColors["4"]!),
                            ("High", movementColors["5"]!),
                        ])
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                        MiniStat(title: "Walking equivalent", value: distanceText(activity.equivalent_walking_distance))
                        MiniStat(title: "Active time", value: durationText(activity.low_activity_time + activity.medium_activity_time + activity.high_activity_time) ?? "—")
                        MiniStat(title: "Sedentary", value: durationText(activity.sedentary_time) ?? "—")
                        MiniStat(title: "Resting", value: durationText(activity.resting_time) ?? "—")
                        MiniStat(title: "Non-wear", value: durationText(activity.non_wear_time) ?? "—")
                        MiniStat(title: "Inactivity alerts", value: String(activity.inactivity_alerts))
                        MiniStat(title: "Total energy", value: "\(activity.total_calories) kcal")
                        MiniStat(title: "Average MET", value: activity.average_met_minutes.formatted(.number.precision(.fractionLength(1))))
                    }
                } else {
                    InlineEmptyState(icon: "figure.walk", text: "No daily activity summary is available yet.")
                }

                Divider()

                Label("Movement ribbons use Oura's processed activity classes. HeartSync cannot access or display the ring's raw accelerometer stream.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .ouraCard()
        }
    }

    private let movementColors: [Character: Color] = [
        "0": .gray.opacity(0.22),
        "1": .indigo.opacity(0.45),
        "2": .blue.opacity(0.50),
        "3": .teal.opacity(0.72),
        "4": .green,
        "5": .orange,
    ]

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Timeline",
                subtitle: "Workouts, sessions, tags, and rest mode",
                systemImage: "list.bullet.rectangle.portrait"
            )

            VStack(alignment: .leading, spacing: 0) {
                if timelineItems.isEmpty {
                    InlineEmptyState(icon: "calendar.badge.clock", text: "No recent Oura events are available.")
                } else {
                    ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                        TimelineRow(item: item)
                        if index < timelineItems.count - 1 { Divider().padding(.leading, 42) }
                    }
                }
            }
            .ouraCard()
        }
    }

    private var timelineItems: [TimelineItem] {
        let snapshot = model.oura.snapshot
        var result: [TimelineItem] = []

        result += snapshot.workouts.compactMap { workout in
            guard let date = OuraClient.parseTimestamp(workout.start_datetime) else { return nil }
            let duration = intervalDuration(start: workout.start_datetime, end: workout.end_datetime)
            let calories = workout.calories.map { " · \(Int($0.rounded())) kcal" } ?? ""
            return TimelineItem(
                id: "workout-\(workout.id)",
                date: date,
                title: workout.label ?? pretty(workout.activity) ?? "Workout",
                subtitle: "\(pretty(workout.intensity) ?? "Workout")\(duration.map { " · \($0)" } ?? "")\(calories)",
                icon: "figure.run",
                tint: .orange
            )
        }

        result += snapshot.sessions.compactMap { session in
            guard let date = OuraClient.parseTimestamp(session.start_datetime) else { return nil }
            let motion = session.motion_count?.items.compactMap { $0 }.count ?? 0
            let detail = [pretty(session.mood), motion > 0 ? "\(motion) motion samples" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
            return TimelineItem(
                id: "session-\(session.id)",
                date: date,
                title: pretty(session.type) ?? "Session",
                subtitle: detail.isEmpty ? "Oura session" : detail,
                icon: "figure.mind.and.body",
                tint: .purple
            )
        }

        result += snapshot.enhancedTags.compactMap { tag in
            guard let date = OuraClient.parseTimestamp(tag.start_time) else { return nil }
            let title = tag.custom_name ?? pretty(tag.tag_type_code) ?? "Tag"
            return TimelineItem(
                id: "enhanced-tag-\(tag.id)",
                date: date,
                title: title,
                subtitle: tag.comment ?? "Oura tag",
                icon: "tag.fill",
                tint: .blue
            )
        }

        result += snapshot.tags.compactMap { tag in
            guard let date = OuraClient.parseTimestamp(tag.timestamp) else { return nil }
            let title = tag.tags.first.map(pretty) ?? nil
            return TimelineItem(
                id: "tag-\(tag.id)",
                date: date,
                title: title ?? "Tag",
                subtitle: tag.text ?? tag.tags.dropFirst().joined(separator: ", "),
                icon: "tag",
                tint: .blue
            )
        }

        result += snapshot.restModePeriods.compactMap { period in
            let date = OuraClient.parseTimestamp(period.start_time) ?? OuraClient.parseDay(period.start_day)
            guard let date else { return nil }
            return TimelineItem(
                id: "rest-\(period.id)",
                date: date,
                title: "Rest mode",
                subtitle: period.end_day.map { "Through \(dayLabel($0))" } ?? "Currently recorded",
                icon: "bed.double.circle.fill",
                tint: .indigo
            )
        }

        return Array(result.sorted { $0.date > $1.date }.prefix(12))
    }

    // MARK: - Ring

    private var ringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Ring",
                subtitle: "Battery and hardware reported by Oura",
                systemImage: "circle.circle"
            )

            VStack(alignment: .leading, spacing: 16) {
                let battery = model.oura.snapshot.latestBatteryLevel
                let ring = model.oura.snapshot.currentRing

                if let battery {
                    HStack(spacing: 12) {
                        Image(systemName: batteryIcon(for: battery.level))
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
                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                        MiniStat(title: "Generation", value: pretty(ring.hardware_type) ?? "—")
                        MiniStat(title: "Design", value: pretty(ring.design) ?? "—")
                        MiniStat(title: "Color", value: pretty(ring.color) ?? "—")
                        MiniStat(title: "Size", value: ring.size.map(String.init) ?? "—")
                        MiniStat(title: "Firmware", value: ring.firmware_version ?? "—")
                        MiniStat(title: "Set up", value: dateTimeLabel(ring.set_up_at))
                    }
                }

                if battery == nil, ring == nil {
                    InlineEmptyState(icon: "battery.0percent", text: "No ring battery or configuration record is available.")
                }
            }
            .ouraCard()
        }
    }

    // MARK: - Endpoint issues

    private var endpointIssuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Some data is unavailable",
                subtitle: "Cached data above remains visible",
                systemImage: "exclamationmark.triangle.fill"
            )

            VStack(spacing: 0) {
                ForEach(Array(model.oura.endpointIssues.enumerated()), id: \.element.id) { index, issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.isPermissionIssue ? "lock.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(issue.isPermissionIssue ? .orange : .red)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.endpoint.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if index < model.oura.endpointIssues.count - 1 { Divider().padding(.leading, 32) }
                }
            }
            .padding(.horizontal, 14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.orange.opacity(0.20))
            }
        }
    }

    // MARK: - OAuth and data access

    private var oauthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "OAuth & data access",
                subtitle: "What HeartSync can ask Oura to share",
                systemImage: "key.fill"
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.oura.hasAuthorization ? "Oura authorization saved" : "Authorization needed")
                            .font(.headline)
                        if let expiry = model.oura.authorizationExpiresAt {
                            Text("Expires \(expiry.formatted(.relative(presentation: .named))) · \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Connect again to refresh this cached dashboard.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: model.oura.hasAuthorization ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(model.oura.hasAuthorization ? .green : .orange)
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text("Permissions")
                        .font(.subheadline.weight(.semibold))
                    ForEach(OuraOAuthSession.requestedScopes, id: \.self) { scope in
                        ScopeRow(scope: scope, state: scopeState(scope))
                    }
                }

                Button {
                    showingSetup = true
                } label: {
                    Label(model.oura.hasAuthorization ? "Update permissions" : "Reconnect Oura", systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HonestInfoRow(
                        icon: "lock.shield.fill",
                        tint: .green,
                        title: "On-device privacy",
                        message: "The access token stays in the device-only Keychain. Dashboard records are cached locally and are not sent to a HeartSync server."
                    )
                    HonestInfoRow(
                        icon: "icloud.and.arrow.down",
                        tint: .blue,
                        title: "Cloud timing",
                        message: "This is the latest data Oura has processed—not a live feed. Sleep and readiness may require opening the Oura app and syncing the ring."
                    )
                    HonestInfoRow(
                        icon: "waveform.path",
                        tint: .orange,
                        title: "Movement limits",
                        message: "The public API provides processed movement classes, MET values, and session motion counts. It does not expose raw accelerometer samples."
                    )
                }
            }
            .ouraCard()
        }
    }

    private func scopeState(_ scope: String) -> PermissionDisplayState {
        guard model.oura.hasAuthorization else { return .missing }
        guard let granted = model.oura.reportedGrantedScopes else { return .unknown }
        if scope == "spo2Daily" || scope == "spo2" {
            return granted.contains("spo2Daily") || granted.contains("spo2") ? .granted : .missing
        }
        return granted.contains(scope) ? .granted : .missing
    }

    // MARK: - Formatting

    private func dayLabel(_ day: String?) -> String {
        guard let day else { return "No recent record" }
        if let date = OuraClient.parseDay(day) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return day
    }

    private func number(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    private func signed(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(digits)))
        if value > 0 { return "+\(magnitude)" }
        if value < 0 { return "−\(magnitude)" }
        return magnitude
    }

    private func durationText(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func distanceText(_ meters: Int) -> String {
        if meters >= 1_000 {
            let kilometers = Double(meters) / 1_000
            return "\(kilometers.formatted(.number.precision(.fractionLength(1)))) km"
        }
        return "\(meters) m"
    }

    private func bedtimeText(_ timestamp: String?) -> String {
        guard let date = OuraClient.parseTimestamp(timestamp) else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func dateTimeLabel(_ timestamp: String?) -> String {
        guard let date = OuraClient.parseTimestamp(timestamp) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func intervalDuration(start: String, end: String) -> String? {
        guard let startDate = OuraClient.parseTimestamp(start),
              let endDate = OuraClient.parseTimestamp(end)
        else { return nil }
        return durationText(Int(max(0, endDate.timeIntervalSince(startDate))))
    }

    private func pretty(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func resilienceProgress(_ raw: String?) -> Double? {
        switch raw?.lowercased() {
        case "limited":     0.18
        case "adequate":    0.38
        case "solid":       0.58
        case "strong":      0.78
        case "exceptional": 1.0
        default:             nil
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Supporting views

private struct SectionHeading: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.indigo)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeaderPill: View {
    var icon: String
    var text: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

private struct ScoreCard: View {
    var title: String
    var value: String
    var progress: Double?
    var detail: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                if let progress {
                    ZStack {
                        Circle()
                            .stroke(tint.opacity(0.14), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: min(max(progress, 0), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                }
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ouraCard()
        .accessibilityElement(children: .combine)
    }
}

private struct BiomarkerItem: Identifiable {
    var id: String
    var title: String
    var value: String
    var unit: String
    var detail: String
    var icon: String
    var tint: Color
}

private struct BiomarkerCard: View {
    var item: BiomarkerItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(item.title, systemImage: item.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tint)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.value)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(item.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ouraCard()
        .accessibilityElement(children: .combine)
    }
}

private struct HeartChartPoint: Identifiable {
    var id: String
    var date: Date
    var bpm: Double
}

private struct MiniStat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoricalRibbon: View {
    var values: [Character]
    var colors: [Character: Color]
    var fallback: Color
    var accessibilityText: String

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let width = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let rect = CGRect(
                    x: CGFloat(index) * width,
                    y: 0,
                    width: max(width + 0.5, 1),
                    height: size.height
                )
                context.fill(Path(rect), with: .color(colors[value] ?? fallback))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.secondary.opacity(0.12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

private struct RibbonLegend: View {
    var items: [(String, Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.1)
                        .frame(width: 7, height: 7)
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TimelineItem: Identifiable {
    var id: String
    var date: Date
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color
}

private struct TimelineRow: View {
    var item: TimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.subheadline)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(item.date, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct InlineEmptyState: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

private struct HonestInfoRow: View {
    var icon: String
    var tint: Color
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum PermissionDisplayState {
    case granted
    case unknown
    case missing
}

private struct ScopeRow: View {
    var scope: String
    var state: PermissionDisplayState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(scopeTitle)
                    .font(.subheadline)
                Text(scopeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.10), in: Capsule())
        }
    }

    private var icon: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .missing: "lock.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .granted: .green
        case .unknown: .blue
        case .missing: .orange
        }
    }

    private var stateTitle: String {
        switch state {
        case .granted: "Granted"
        case .unknown: "Checked by Oura"
        case .missing: "Missing"
        }
    }

    private var scopeTitle: String {
        switch scope {
        case "personal": "Profile & ring"
        case "daily": "Daily health summaries"
        case "heartrate": "Heart-rate samples"
        case "workout": "Workouts"
        case "tag": "Tags & rest mode"
        case "session": "Guided sessions"
        case "spo2Daily", "spo2": "Nightly blood oxygen"
        case "stress": "Stress & resilience"
        case "heart_health": "Heart health"
        case "ring_configuration": "Ring details"
        default: scope
        }
    }

    private var scopeDescription: String {
        switch scope {
        case "personal": "Profile information"
        case "daily": "Sleep, activity, readiness, and daily recovery"
        case "heartrate": "Oura's processed heart-rate time series"
        case "workout": "Detected and manually entered workouts"
        case "tag": "Tags, enhanced tags, and rest-mode periods"
        case "session": "Meditation, breathing, rest, and motion summaries"
        case "spo2Daily", "spo2": "Sleep SpO₂ average and disturbance index"
        case "stress": "Daily stress, recovery, and resilience"
        case "heart_health": "Cardiovascular age and VO₂ max"
        case "ring_configuration": "Ring battery, hardware, and firmware"
        default: "Oura data permission"
        }
    }
}

private extension View {
    func ouraCard() -> some View {
        padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.secondary.opacity(0.08))
            }
    }
}
