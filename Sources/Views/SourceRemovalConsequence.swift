import Foundation

/// The wording of a removal confirmation, built before anything is deleted.
///
/// Removing a source runs `DELETE FROM readings WHERE source_id = ?`. For a Bluetooth sensor
/// that history exists nowhere else, and a single swipe used to perform it with no second
/// step. This states the consequence in numbers and says what can and cannot come back, so
/// the destructive button is pressed knowing exactly what it does.
///
/// A pure value so the wording is testable without presenting a dialog.
struct SourceRemovalConsequence: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Delete one source and every reading stored for it.
        case removeSource
        /// Sign out of Oura, and delete the Oura readings stored on this device.
        case disconnectOura
    }

    var action: Action
    var title: String
    var message: String
    var confirmTitle: String
    /// True when there is, or may be, stored history worth exporting first. An unknown
    /// count offers the export too: not being able to count is not evidence of nothing.
    var offersExport: Bool

    /// How far back an Oura sync re-fetches after reconnecting (`OuraManager.sync(days:)`).
    static let ouraResyncDays = 14

    /// - Parameters:
    ///   - source: the source being removed. Nil only for an Oura connection that has not
    ///     stored anything yet.
    ///   - history: the stored-row summary, or nil when it could not be read.
    ///   - now: reference date, so the "since" text can omit the current year.
    static func make(
        action: Action,
        source: DataSource?,
        history: HealthStore.SourceHistorySummary?,
        now: Date = .now
    ) -> SourceRemovalConsequence {
        let name = source?.displayName ?? "Oura"
        let title = action == .disconnectOura ? "Disconnect Oura?" : "Remove \(name)?"

        let stored: String
        // True when readings are, or may be, deleted. An unknown count counts as "may be".
        let deletesReadings: Bool
        if source == nil {
            stored = "No Oura readings are stored on this device yet."
            deletesReadings = false
        } else if let history {
            if history.readingCount == 0 {
                stored = "No readings from \(name) are stored on this device."
                deletesReadings = false
            } else {
                let count = history.readingCount
                if let earliest = history.earliest {
                    stored = String(
                        localized: "removal.deletes.since",
                        defaultValue: "Deletes \(count) readings from \(name) recorded since \(dayText(earliest, now: now)).",
                        comment: "Removal confirmation. Arguments: how many readings are deleted, the device name, the day the earliest was recorded."
                    )
                } else {
                    stored = String(
                        localized: "removal.deletes",
                        defaultValue: "Deletes \(count) readings from \(name).",
                        comment: "Removal confirmation. Arguments: how many readings are deleted, the device name."
                    )
                }
                deletesReadings = true
            }
        } else {
            stored = "HeartSync could not count the readings stored for \(name). Removing it deletes all of them."
            deletesReadings = true
        }

        // Says "delete readings" only when that is what happens, so the button never
        // overstates or understates its own effect.
        let confirmTitle: String
        switch (action, deletesReadings) {
        case (.removeSource, true): confirmTitle = "Remove and delete readings"
        case (.removeSource, false): confirmTitle = "Remove device"
        case (.disconnectOura, true): confirmTitle = "Disconnect and delete readings"
        case (.disconnectOura, false): confirmTitle = "Disconnect"
        }

        let recovery: String
        switch (action, source?.transport) {
        case (.disconnectOura, _), (_, .oura):
            recovery = "It also signs out of Oura. Reconnecting restores only the last \(ouraResyncDays) days."
        case (_, .bluetooth):
            recovery = "Bluetooth history cannot be downloaded again."
        case (_, .healthKit):
            recovery = "Apple Health keeps its own copy, but HeartSync does not import these samples again on its own. New samples from this source will still appear."
        case (_, .manual), (_, nil):
            recovery = "Estimates are recomputed only for the current period."
        }

        return SourceRemovalConsequence(
            action: action,
            title: title,
            message: "\(stored) \(recovery)",
            confirmTitle: confirmTitle,
            offersExport: deletesReadings
        )
    }

    /// "3 Aug", or "3 Aug 2025" when the history started in an earlier year.
    private static func dayText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
