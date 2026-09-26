import SwiftUI

/// Saved comparison sessions: exact spans a user can come back to.
///
/// A rolling preset answers "how are my devices doing lately". This answers "what happened
/// during that walk", which needs the analysed seconds to stay put while cloud and
/// HealthKit data for them keeps arriving afterwards.
struct ComparisonSessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Called with the session the user chose to open.
    var open: (ComparisonSession) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.sessions.loadState == .failed {
                    Section {
                        Label("Saved sessions are temporarily unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(model.sessions.loadIssue ?? "The sessions archive could not be read. Existing bytes were preserved and nothing new will be written until it loads.")
                            .font(.caption)
                    }
                }

                if model.sessions.sessions.isEmpty {
                    Section {
                        EmptyStateView(
                            systemImage: "bookmark",
                            title: "No saved sessions",
                            message: "Save a comparison to come back to the exact same period later — after your ring or Apple Health has finished syncing that time range, for example."
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(model.sessions.sessions) { session in
                            Button {
                                open(session)
                                dismiss()
                            } label: {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { model.sessions.sessions[$0].id }
                            Task { for id in doomed { await model.sessions.remove(id: id) } }
                        }
                    } footer: {
                        Text("A session stores the period, the devices, and your own label — never a copy of the readings or of the result. Re-opening one re-runs the analysis against your current data, so a session is not a fixed record. Export a pair from its detail screen for that.")
                    }
                }
            }
            .navigationTitle("Saved sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// States that a saved session's fixed span is in force, and whether its data has moved.
///
/// Shown on Compare and on both detail screens opened from it, in place of the rolling range
/// picker. A drill-down from "Morning walk, 07:00–08:00" must analyse those seconds and say
/// so; showing the picker there would imply the last 24 hours, a different analysis.
struct ComparisonSessionBanner: View {
    @Environment(AppModel.self) private var model
    var session: ComparisonSession
    /// What changed since the session was last opened. Compare computes it on open.
    var revisitNotice: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(session.displayTitle, systemImage: "bookmark.fill")
                .font(.subheadline.weight(.semibold))
            Text("\(session.interval.start.formatted(date: .abbreviated, time: .shortened)) \u{2013} \(session.interval.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !session.context.isEmpty {
                Text(session.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Saved session: this analysis covers exactly these times, not a rolling range.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A saved session is a saved *selection*. Data for its period keeps arriving,
            // so a revisit says when the result is no longer the one that was seen.
            if let revisitNotice {
                Label(revisitNotice, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let missing = session.missingSourceIDs(in: model.store.sources)
            if !missing.isEmpty {
                Label(
                    "\(missing.count) saved \(missing.count == 1 ? "device is" : "devices are") no longer set up, so this is not the comparison that was saved.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    var session: ComparisonSession

    var body: some View {
        let missing = session.missingSourceIDs(in: model.store.sources)
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle)
                .font(.subheadline.weight(.medium))
            Text(intervalText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !session.context.isEmpty {
                // Explicitly the user's own words: HeartSync does not read workout
                // metadata from HealthKit and must not imply this came from one.
                Label(session.context, systemImage: "text.quote")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(session.sourceIDs, id: \.self) { id in
                    SourceDot(color: model.store.source(id: id)?.color ?? .gray, size: 7)
                }
                Text("\(session.sourceIDs.count) \(session.sourceIDs.count == 1 ? "device" : "devices")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !missing.isEmpty {
                Label(
                    "\(missing.count) of these \(missing.count == 1 ? "devices is" : "devices are") no longer set up. The comparison will not be the one you saved.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Absolute seconds rendered in the reader's current zone. Travelling changes the words
    /// here, never which readings the session analyses.
    private var intervalText: String {
        let start = session.interval.start
        let end = session.interval.end
        return "\(start.formatted(date: .abbreviated, time: .shortened)) \u{2013} \(end.formatted(date: .omitted, time: .shortened))"
    }
}

/// Captures an exact period and the user's own context for it.
struct SaveComparisonSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var start: Date
    @State var end: Date
    @State private var title = ""
    @State private var context = ""
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $start)
                    DatePicker("End", selection: $end, in: start...)
                } header: {
                    Text("Exact period")
                } footer: {
                    Text("Saved as absolute times. Re-opening analyses the same seconds however long ago it was, and whatever time zone you are in.")
                }

                Section {
                    TextField("Title", text: $title)
                    TextField("What were you doing?", text: $context)
                } header: {
                    Text("Your notes")
                } footer: {
                    Text("Both are your own words. HeartSync does not read workouts from Apple Health, so this label is not taken from a recorded activity. Saving a session records no workout and starts no measurement.")
                }

                Section {
                    LabeledContent("Devices included") { Text("\(includedSourceIDs.count)") }
                } footer: {
                    Text("The devices currently included in your comparison. Hidden devices are not saved with the session.")
                }
            }
            .navigationTitle("Save session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(end <= start || includedSourceIDs.isEmpty)
                }
            }
            .alert("Could not save", isPresented: $saveFailed) {
                Button("OK", role: .cancel) { saveFailed = false }
            } message: {
                Text("The saved-sessions file could not be written. Nothing else was changed.")
            }
        }
    }

    private var includedSourceIDs: [String] {
        let hidden = model.settings.snapshot.comparisonHidden
        return model.store.enabledSources.map(\.id).filter { !hidden.contains($0) }.sorted()
    }

    private func save() {
        let session = ComparisonSession(
            title: title,
            context: context,
            interval: DateInterval(start: start, end: max(start, end)),
            sourceIDs: includedSourceIDs
        )
        Task {
            if await model.sessions.save(session) {
                dismiss()
            } else {
                saveFailed = true
            }
        }
    }
}
