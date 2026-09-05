import SwiftUI

/// A ring-first view of everything Oura has most recently processed and uploaded.
///
/// Oura is a cloud source, not a live Bluetooth stream. Cached records therefore stay on
/// screen through partial endpoint failures and every freshness label refers to the cloud
/// sync, never to a live sensor connection.
///
/// This file owns only the page shell: the connected/disconnected states, the connection
/// header, and the endpoint-issue list. Each card section lives in `Sources/Views/Oura` and
/// receives the slice of `OuraSnapshot` it renders as a parameter instead of reading
/// `AppModel`, so the sections stay independently previewable and none of them can quietly
/// start reaching for a different source of truth.
struct OuraDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSetup = false

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

                    Text("Oura is an optional advanced integration")
                        .font(.title2.bold())
                    Text("Bluetooth sensors and Apple Health work without Oura. This developer build can also read Oura Cloud data after you create your own Oura OAuth application and paste its public Client ID.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                    Button {
                        showingSetup = true
                    } label: {
                        Label("Set up Oura (advanced)", systemImage: "link")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 26)

                VStack(alignment: .leading, spacing: 12) {
                    OuraHonestInfoRow(
                        icon: "hammer.fill",
                        tint: .orange,
                        title: "Personal/developer setup",
                        message: "HeartSync does not ship a shared first-party Oura client identity. Each user who enables this optional integration creates an OAuth application."
                    )
                    OuraHonestInfoRow(
                        icon: "lock.shield.fill",
                        tint: .green,
                        title: "Private by design",
                        message: "Your OAuth token stays in this device's Keychain. Imported Oura records are cached locally."
                    )
                    OuraHonestInfoRow(
                        icon: "icloud.and.arrow.down",
                        tint: .blue,
                        title: "Latest Oura cloud data",
                        message: "The ring uploads through the Oura app. Sleep and readiness can lag until that sync finishes."
                    )
                    OuraHonestInfoRow(
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
            // Eager stack on purpose: this page is a fixed handful of section cards, so
            // lazy loading buys nothing and only delays the same work until mid-scroll.
            //
            // The hang this replaced was never the stack. `OuraHeartRateSection` derived
            // its chart points in computed properties and read one of them from inside the
            // `Chart` content closure, which Swift Charts runs once per plotted sample, so
            // every sample re-parsed the whole cached heart-rate collection. Making the
            // stack eager only moved the freeze from mid-scroll to tab entry; the fix is in
            // `OuraHeartRateSeries`, which resolves that set exactly once.
            VStack(alignment: .leading, spacing: 24) {
                connectionHeader

                if model.oura.snapshot.hasData {
                    sections
                } else {
                    waitingForDataCard
                }

                if !model.oura.endpointIssues.isEmpty {
                    endpointIssuesSection
                }

                incompleteCollectionsSection

                OuraOAuthSection(
                    hasAuthorization: model.oura.hasAuthorization,
                    expiresAt: model.oura.authorizationExpiresAt,
                    grantedScopes: model.oura.reportedGrantedScopes,
                    onManagePermissions: { showingSetup = true }
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .refreshable {
            guard model.oura.hasAuthorization else { return }
            await model.oura.sync()
        }
    }

    /// Every card section, built from a single read of the cached snapshot so the whole page
    /// describes one cloud sync rather than each section resolving its own.
    @ViewBuilder
    private var sections: some View {
        let snapshot = model.oura.snapshot
        // Resolved once and shared: each `latest…` accessor is a linear scan of its
        // collection, and two sections read each of these.
        let activity = snapshot.latestActivity
        let readiness = snapshot.latestReadiness
        let sleep = snapshot.latestSleep

        OuraScoresSection(
            activity: activity,
            readiness: readiness,
            sleepScore: snapshot.latestSleepScore,
            resilience: snapshot.latestResilience,
            stress: snapshot.latestStress
        )
        OuraBiomarkersSection(
            heartRate: snapshot.latestHeartRate,
            sleep: sleep,
            readiness: readiness,
            oxygen: snapshot.latestOxygen,
            cardiovascularAge: snapshot.latestCardiovascularAge,
            vo2Max: snapshot.latestVO2Max
        )
        OuraHeartRateSection(heartRates: snapshot.heartRates)
        OuraSleepSection(sleep: sleep)
        OuraMovementSection(activity: activity)
        OuraTimelineSection(
            workouts: snapshot.workouts,
            sessions: snapshot.sessions,
            enhancedTags: snapshot.enhancedTags,
            tags: snapshot.tags,
            restModePeriods: snapshot.restModePeriods
        )
        OuraRingSection(
            battery: snapshot.latestBatteryLevel,
            ring: snapshot.currentRing
        )
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
                    OuraHeaderPill(
                        icon: OuraFormat.batteryIcon(for: battery.level),
                        text: "\(battery.level)%",
                        tint: battery.level <= 15 ? .red : .white
                    )
                }
                let issueCount = model.oura.endpointIssues.count
                let incompleteCount = incompleteCollections.count
                let collectionsCurrent = issueCount == 0 && incompleteCount == 0
                OuraHeaderPill(
                    icon: collectionsCurrent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    text: collectionsPillText(issues: issueCount, incomplete: incompleteCount),
                    tint: collectionsCurrent ? .white : .yellow
                )
                if model.oura.snapshot.totalRecordCount > 0 {
                    OuraHeaderPill(
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

    /// The header must never read "Collections current" while a collection was only partly
    /// imported. An unavailable collection is the louder problem, so it is reported first;
    /// a truncated one is still reported rather than rounded up to healthy.
    private func collectionsPillText(issues: Int, incomplete: Int) -> String {
        if issues > 0 { return "\(issues) unavailable" }
        if incomplete > 0 { return "\(incomplete) partly loaded" }
        return "Collections current"
    }

    private var connectionSubtitle: String {
        if case .error(let message) = model.oura.status { return message }
        if let last = model.oura.lastSyncedAt {
            return "Cloud sync \(last.formatted(.relative(presentation: .named)))"
        }
        return model.oura.hasAuthorization ? "Connected · waiting for the first sync" : "Authorization required to refresh"
    }

    // MARK: - Endpoint issues

    private var endpointIssuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Unavailable" alone would be wrong now: an issue here can also be a
            // collection that imported only a prefix. Each issue's own message says which.
            OuraSectionHeading(
                title: "Some data needs attention",
                subtitle: "Cached data above remains visible",
                systemImage: "exclamationmark.triangle.fill"
            )
            .accessibilityIdentifier("oura.endpointIssues")

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

    // MARK: - Incomplete collections

    /// Collections whose last page walk stopped at the client's page ceiling, in
    /// `OuraEndpoint.allCases` order so the list is stable between renders.
    ///
    /// `OuraSnapshot.truncatedCollections` is keyed by `OuraEndpoint.rawValue` and persisted,
    /// so a relaunch still knows the cached records are a prefix. A raw value this build does
    /// not recognise is dropped rather than shown as an unnamed row.
    private var incompleteCollections: [OuraEndpoint] {
        let truncated = model.oura.snapshot.truncatedCollections
        guard !truncated.isEmpty else { return [] }
        return OuraEndpoint.allCases.filter { truncated.contains($0.rawValue) }
    }

    /// Says outright that a collection is a partial import. Without this the cards above
    /// would present a prefix of the user's history as the whole of it.
    @ViewBuilder
    private var incompleteCollectionsSection: some View {
        let collections = incompleteCollections
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                OuraSectionHeading(
                    title: "Some collections are incomplete",
                    subtitle: "Imported in part, not in full",
                    systemImage: "ellipsis.circle.fill"
                )

                VStack(spacing: 0) {
                    ForEach(Array(collections.enumerated()), id: \.element.id) { index, endpoint in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "ellipsis.circle.fill")
                                .foregroundStyle(.yellow)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(endpoint.title)
                                    .font(.subheadline.weight(.semibold))
                                Text("Oura holds more records than one sync imports, so what is cached here is part of this collection, not all of it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        if index < collections.count - 1 { Divider().padding(.leading, 32) }
                    }
                }
                .padding(.horizontal, 14)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.yellow.opacity(0.20))
                }
            }
        }
    }
}
