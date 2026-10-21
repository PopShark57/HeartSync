import Foundation

/// What the Now brief may say: one plain sentence per reading, built from the same snapshot
/// the cards draw, and nothing else.
///
/// The on-device model selects complete sentences; their values, units, provenance,
/// evidence counts and ages are always rendered by HeartSync.
struct NowBriefFacts: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        /// The reading's metric; blood pressure is filed under systolic.
        var kind: MetricKind
        var sentence: String
        var isEstimate: Bool
        var isCurrent: Bool
    }

    var items: [Item]
    /// Changes only when what the brief would say changes: values are rounded to the
    /// precision a sentence would use, and ages to coarse steps. A 1 Hz strap moving heart
    /// rate by a beat therefore asks for no new brief.
    var key: String

    var lines: [String] { items.map(\.sentence) }

    /// The readings a brief describes, most immediate first. Resting heart rate and VO₂ max
    /// describe days, not the present, and are left to their cards.
    static let order: [MetricKind] = [
        .heartRate, .stress, .bloodPressureSystolic, .spo2, .bodyTemperature, .respiratoryRate, .hrvRMSSD, .hrvSDNN,
    ]

    /// Nil when the snapshot has no card to describe.
    static func build(metrics: [MetricSummary], stressBand: StressModel.Band?, now: Date) -> NowBriefFacts? {
        let byKind = Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [Item] = []
        var keyParts: [String] = []
        var hasHRV = false

        for kind in order {
            guard let summary = byKind[kind], let value = summary.headline else { continue }
            // One HRV line is enough for a present-tense summary.
            if kind == .hrvRMSSD || kind == .hrvSDNN {
                guard !hasHRV else { continue }
                hasHRV = true
            }
            let isEstimate = kind == .stress
                || (summary.rows.contains { $0.provenance == .estimated } && !summary.rows.contains { $0.provenance != .estimated })

            let subject: String
            var valueText: String
            var keyValue: String
            switch kind {
            case .bloodPressureSystolic:
                guard let diastolic = byKind[.bloodPressureDiastolic]?.headline else { continue }
                subject = "blood pressure"
                valueText = "\(format(value, 0))/\(format(diastolic, 0)) mmHg"
                keyValue = "\(rounded(value, to: 2))/\(rounded(diastolic, to: 2))"
            case .stress:
                subject = "stress level"
                valueText = "\(format(value, 0)) out of 100"
                if let stressBand, summary.isCurrent { valueText += " (\(stressBand.rawValue))" }
                keyValue = "\(rounded(value, to: 5))"
            default:
                subject = spokenName(kind)
                valueText = "\(format(value, kind.fractionDigits))\(spokenUnit(kind))"
                keyValue = "\(rounded(value, to: step(for: kind)))"
            }

            var sentence: String
            let age: String
            if summary.isCurrent {
                age = "now"
                sentence = "\(isEstimate ? "Estimated " + subject : subject.capitalizedFirstLetter) is \(valueText) now"
            } else if let newest = summary.newestTimestamp {
                age = ageStep(now.timeIntervalSince(newest))
                sentence = "\(isEstimate ? "Estimated " + subject : subject.capitalizedFirstLetter) was \(valueText) when last reported, \(ageText(now.timeIntervalSince(newest))) ago"
            } else {
                continue
            }
            if kind == .stress { sentence += ", computed by HeartSync" }
            if let comparison = summary.comparison {
                switch comparison.severity {
                case .agreeing: sentence += "; \(comparison.sourceCount) devices agree"
                case .notable:  sentence += "; \(comparison.sourceCount) devices differ somewhat"
                case .major:    sentence += "; \(comparison.sourceCount) devices disagree"
                }
            }
            sentence += "."

            items.append(Item(kind: kind, sentence: sentence, isEstimate: isEstimate, isCurrent: summary.isCurrent))
            keyParts.append("\(kind.rawValue)=\(keyValue)@\(age)#\(summary.rows.map { $0.provenance.rawValue }.sorted().joined(separator: ","))#\(isEstimate)#\(summary.comparison.map { "\($0.severity.rawValue):\($0.sourceCount)" } ?? "none")")
        }
        guard !items.isEmpty else { return nil }
        return NowBriefFacts(items: items, key: keyParts.joined(separator: ";"))
    }

    /// The prompt handed to the model: the facts and nothing else.
    var prompt: String {
        "Readings:\n" + lines.map { "- " + $0 }.joined(separator: "\n")
    }

    // MARK: Wording

    /// Words a reader and the check both recognise as naming each reading.
    static func keywords(for kind: MetricKind) -> [String] {
        switch kind {
        case .heartRate:              ["heart rate", "pulse"]
        case .stress:                 ["stress"]
        case .bloodPressureSystolic, .bloodPressureDiastolic: ["blood pressure", "pressure"]
        case .spo2:                   ["blood oxygen", "oxygen", "spo2", "spo\u{2082}", "saturation"]
        case .bodyTemperature:        ["temperature"]
        case .respiratoryRate:        ["respiratory", "respiration", "breathing", "breath"]
        case .hrvRMSSD, .hrvSDNN:     ["heart rate variability", "hrv", "rmssd", "sdnn"]
        case .restingHeartRate:       ["resting heart rate"]
        case .vo2Max:                 ["vo2", "vo\u{2082}"]
        }
    }

    private static func spokenName(_ kind: MetricKind) -> String {
        switch kind {
        case .heartRate:       "heart rate"
        case .spo2:            "blood oxygen"
        case .bodyTemperature: "temperature"
        case .respiratoryRate: "breathing rate"
        case .hrvRMSSD:        "HRV (RMSSD)"
        case .hrvSDNN:         "HRV (SDNN)"
        default:               kind.exportTitle.lowercased()
        }
    }

    private static func spokenUnit(_ kind: MetricKind) -> String {
        switch kind {
        case .spo2:            "%"
        case .respiratoryRate: " breaths per minute"
        default:               " " + kind.exportUnit
        }
    }

    /// Fixed "." decimals, so the facts and the check agree whatever the locale.
    private static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func step(for kind: MetricKind) -> Double {
        switch kind {
        case .heartRate, .restingHeartRate, .hrvRMSSD, .hrvSDNN: 5
        case .bodyTemperature: 0.2
        default: 1
        }
    }

    private static func rounded(_ value: Double, to step: Double) -> String {
        format((value / step).rounded() * step, step < 1 ? 1 : 0)
    }

    /// "12 minutes", "3 hours", "2 days".
    static func ageText(_ seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        if elapsed < 3_600 {
            let minutes = max(1, Int((elapsed / 60).rounded()))
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        if elapsed < 86_400 {
            let hours = Int((elapsed / 3_600).rounded())
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let days = Int((elapsed / 86_400).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Coarse age steps for the key, so a reading growing a minute older asks for no new brief.
    private static func ageStep(_ seconds: TimeInterval) -> String {
        if seconds < 3_600 { return "m\(Int(seconds / 900))" }
        if seconds < 86_400 { return "h\(Int(seconds / 3_600))" }
        return "d\(Int(seconds / 86_400))"
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// Accepts only canonical sentences, in order. No model-authored measurement prose crosses
/// this boundary: substring or number-set matching cannot preserve semantic roles.
enum NowBriefCheck {
    static let maximumLength = 640

    /// The brief to show, or nil when it must not be shown.
    static func accepted(_ text: String, facts: NowBriefFacts) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        // Only complete canonical clauses may cross the model boundary. Values, units,
        // ordered pressure components, ages, provenance, and counts stay bound together.
        var rest = trimmed[...]
        var acceptedCount = 0
        for item in facts.items {
            guard rest.hasPrefix(item.sentence) else { continue }
            rest = rest.dropFirst(item.sentence.count)
            rest = rest.drop(while: { $0.isWhitespace })
            acceptedCount += 1
        }
        guard rest.isEmpty, acceptedCount > 0 else { return nil }
        return trimmed
    }

}

/// Generation throttling never grants permission to keep showing obsolete facts.
struct NowBriefDisplay: Sendable {
    static let lifetime: TimeInterval = 180
    var text: String
    var facts: NowBriefFacts
    var generatedAt: Date

    func isValid(for current: NowBriefFacts?, now: Date, available: Bool) -> Bool {
        available && current == facts && now >= generatedAt && now.timeIntervalSince(generatedAt) < Self.lifetime
    }
}
