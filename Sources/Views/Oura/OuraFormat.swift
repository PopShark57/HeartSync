import Foundation

/// Presentation-only formatting shared by the Oura dashboard sections.
///
/// Every helper is pure, `nonisolated`, and free of analysis: it renders a value Oura has
/// already processed. Nothing here converts units, derives a metric, or decides agreement —
/// that work belongs to `MetricKind` and `ComparisonEngine`, and an Oura figure formatted
/// here must never be presented as a direct HeartSync measurement.
///
/// These were `private` methods on `OuraDashboardView` before the screen was split by
/// section; the bodies are unchanged.
enum OuraFormat {

    // MARK: - Dates

    /// Oura `day` strings are the ring's local day. When one cannot be parsed the raw string
    /// is shown rather than a guessed date.
    ///
    /// Oura day strings are calendar dates, and `OuraClient.parseDay` anchors them to UTC
    /// midnight. Formatting that instant in the phone's zone would name the previous day
    /// anywhere west of Greenwich, so the label is produced by the client's UTC-anchored,
    /// locale-driven formatter instead.
    static func dayLabel(_ day: String?) -> String {
        guard let day else { return "No recent record" }
        return OuraClient.dayLabel(day) ?? day
    }

    static func bedtimeText(_ timestamp: String?) -> String {
        guard let date = OuraClient.parseTimestamp(timestamp) else { return "—" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dateTimeLabel(_ timestamp: String?) -> String {
        guard let date = OuraClient.parseTimestamp(timestamp) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func intervalDuration(start: String, end: String) -> String? {
        guard let startDate = OuraClient.parseTimestamp(start),
              let endDate = OuraClient.parseTimestamp(end)
        else { return nil }
        return durationText(Int(max(0, endDate.timeIntervalSince(startDate))))
    }

    // MARK: - Numbers

    static func number(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Signed rendering for values that are deviations from a baseline, not absolute
    /// measurements. The sign is part of the meaning and is never dropped.
    static func signed(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(digits)))
        if value > 0 { return "+\(magnitude)" }
        if value < 0 { return "−\(magnitude)" }
        return magnitude
    }

    /// Seconds in, `1h 5m`-style text out. Negative input is treated as no value.
    static func durationText(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Metres in, metres or kilometres out.
    static func distanceText(_ meters: Int) -> String {
        if meters >= 1_000 {
            let kilometers = Double(meters) / 1_000
            return "\(kilometers.formatted(.number.precision(.fractionLength(1)))) km"
        }
        return "\(meters) m"
    }

    // MARK: - Strings and symbols

    /// Oura returns lower-snake-case enumerations; this is display sugar only and must not be
    /// used to compare or key values.
    static func pretty(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Resilience is a category, not a score. The fractions only position the ring; they are
    /// never shown as a number.
    static func resilienceProgress(_ raw: String?) -> Double? {
        switch raw?.lowercased() {
        case "limited":     0.18
        case "adequate":    0.38
        case "solid":       0.58
        case "strong":      0.78
        case "exceptional": 1.0
        default:             nil
        }
    }

    static func batteryIcon(for level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
