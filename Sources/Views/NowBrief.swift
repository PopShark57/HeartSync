import Foundation

/// What the Now brief may say: one plain sentence per reading, built from the same snapshot
/// the cards draw, and nothing else.
///
/// The on-device language model (`NowBriefGenerator`) only joins these sentences into a short
/// paragraph. `NowBriefCheck` then reads the paragraph back reading by reading, and a
/// paragraph that fails is never shown: every number must belong to the reading it is said
/// of, an estimate must be called one and a measurement must not be, a reading that is not
/// live must say how old it is, and nothing may be judged, diagnosed, or advised.
struct NowBriefFacts: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        /// The reading's metric; blood pressure is filed under systolic.
        var kind: MetricKind
        var sentence: String
        /// Numbers the brief may state about this reading, normalised by
        /// `NowBriefCheck.numbers(in:)`.
        var numbers: Set<String>
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

            var numbers = NowBriefCheck.numbers(in: sentence)
            if kind == .stress { numbers.insert("100") }
            items.append(Item(kind: kind, sentence: sentence, numbers: numbers, isEstimate: isEstimate, isCurrent: summary.isCurrent))
            keyParts.append("\(kind.rawValue)=\(keyValue)@\(age)\(summary.comparison.map { "#\($0.severity.rawValue)" } ?? "")")
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

/// Reads a generated brief back against its facts before it may be shown.
enum NowBriefCheck {
    /// Words a summary of readings must not use: they diagnose, prescribe, or alarm.
    static let forbiddenFragments = [
        "diagnos", "disease", "disorder", "hypertens", "hypotens", "fever", "infection",
        "arrhythm", "fibrillation", "afib", "emergency", "medication", "medicine",
        "doctor", "physician", "treatment", "illness", "sick",
    ]

    /// Judgements the readings never make. The stress band's own word is allowed in the
    /// stress part only, because that reading states it.
    static let judgementWords: Set<String> = [
        "normal", "healthy", "unhealthy", "good", "great", "bad", "fine", "excellent", "poor",
        "optimal", "elevated", "high", "low", "concerning", "worrying", "alarming", "abnormal",
        "stable", "steady", "ideal", "safe", "unsafe", "risky",
    ]

    static let maximumLength = 480

    /// Every number in `text`, with a decimal comma read as a point and trailing zeros after
    /// a decimal point dropped, so "36,50" and "36.5" compare equal. Digits inside the names
    /// "SpO2" and "VO2" are not numbers.
    static func numbers(in text: String) -> Set<String> {
        var scrubbed = text
        for name in ["SpO2", "VO2"] {
            scrubbed = scrubbed.replacingOccurrences(of: name, with: " ", options: .caseInsensitive)
        }
        var found: Set<String> = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var number = current
            while number.hasSuffix(".") { number.removeLast() }
            if number.contains(".") {
                while number.hasSuffix("0") { number.removeLast() }
                if number.hasSuffix(".") { number.removeLast() }
            }
            if !number.isEmpty { found.insert(number) }
            current = ""
        }
        var previous: Character?
        for character in scrubbed {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if character == "." || character == ",", !current.isEmpty, previous?.isNumber == true {
                current.append(".")
            } else {
                flush()
            }
            previous = character
        }
        flush()
        return found
    }

    /// One stretch of the brief about one reading: from where it is named to where the next
    /// reading is named.
    struct Part: Equatable {
        var kind: MetricKind
        var text: String
    }

    /// Splits `text` at every reading name, longest names first, so "heart rate
    /// variability" is not read as heart rate. Text before the first name is `preamble`.
    static func parts(of text: String, facts: NowBriefFacts) -> (preamble: String, parts: [Part], unknownReadings: Bool) {
        let lowered = text.lowercased()
        // Each name maps to the item it describes, or to nil for a reading the facts lack.
        // The two HRV metrics and the two halves of blood pressure share their names.
        var byName: [String: MetricKind?] = [:]
        for kind in MetricKind.allCases {
            let item = facts.items.first { item in
                switch kind {
                case .bloodPressureDiastolic: item.kind == .bloodPressureSystolic
                case .hrvRMSSD, .hrvSDNN:     item.kind == .hrvRMSSD || item.kind == .hrvSDNN
                default:                      item.kind == kind
                }
            }
            for name in NowBriefFacts.keywords(for: kind) where byName[name] == nil || item != nil {
                byName[name] = item?.kind
            }
        }
        let names = byName.map { (name: $0.key, kind: $0.value) }.sorted {
            $0.name.count != $1.name.count ? $0.name.count > $1.name.count : $0.name < $1.name
        }

        var marks: [(offset: Int, length: Int, kind: MetricKind?)] = []
        var index = lowered.startIndex
        while index < lowered.endIndex {
            let rest = lowered[index...]
            if let match = names.first(where: { rest.hasPrefix($0.name) }) {
                marks.append((lowered.distance(from: lowered.startIndex, to: index), match.name.count, match.kind))
                index = lowered.index(index, offsetBy: match.name.count)
            } else {
                index = lowered.index(after: index)
            }
        }

        let characters = Array(text)
        // A part starts at the clause that names its reading, not at the name itself, so
        // "Estimated blood pressure" keeps its "Estimated": each boundary moves back to the
        // last clause break before the name.
        func clauseStart(before offset: Int, notBefore floor: Int) -> Int {
            var index = offset
            while index > floor {
                let previous = characters[index - 1]
                if ".,;:()".contains(previous) { return index }
                if index - floor >= 5, String(characters[(index - 5)..<index]).lowercased() == " and " { return index }
                index -= 1
            }
            return floor
        }
        var starts: [Int] = []
        for (position, mark) in marks.enumerated() {
            let floor = position == 0 ? 0 : marks[position - 1].offset + marks[position - 1].length
            starts.append(clauseStart(before: mark.offset, notBefore: floor))
        }
        let preambleEnd = starts.first ?? characters.count
        var parts: [Part] = []
        var unknown = false
        for (position, mark) in marks.enumerated() {
            let end = position + 1 < marks.count ? starts[position + 1] : characters.count
            guard let kind = mark.kind else {
                unknown = true
                continue
            }
            let text = String(characters[starts[position]..<end])
            // Consecutive names of the same reading ("blood pressure ... pressure") join.
            if let last = parts.last, last.kind == kind, position > 0, marks[position - 1].kind == kind {
                parts[parts.count - 1].text += text
            } else {
                parts.append(Part(kind: kind, text: text))
            }
        }
        return (String(characters[0..<preambleEnd]), parts, unknown)
    }

    /// The brief to show, or nil when it must not be shown.
    static func accepted(_ text: String, facts: NowBriefFacts) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        let lowered = trimmed.lowercased()
        guard !forbiddenFragments.contains(where: lowered.contains) else { return nil }

        let split = parts(of: trimmed, facts: facts)
        // A reading the facts do not contain, or a claim before any reading is named.
        guard !split.unknownReadings, !split.parts.isEmpty else { return nil }
        guard numbers(in: split.preamble).isEmpty, !split.preamble.lowercased().contains("estimat"),
              words(in: split.preamble).isDisjoint(with: judgementWords)
        else { return nil }

        for part in split.parts {
            guard let item = facts.items.first(where: { $0.kind == part.kind }) else { return nil }
            let partText = part.text.lowercased()
            guard numbers(in: part.text).isSubset(of: item.numbers) else { return nil }
            // An estimate is always called one; a measurement never is.
            guard partText.contains("estimat") == item.isEstimate else { return nil }
            // A reading that is not live keeps its age.
            if !item.isCurrent, !(partText.contains("ago") || partText.contains("last reported") || partText.contains("earlier")) {
                return nil
            }
            var judged = words(in: part.text).intersection(judgementWords)
            if item.kind == .stress { judged.subtract(StressModel.Band.allCases.map(\.rawValue)) }
            guard judged.isEmpty else { return nil }
        }
        return trimmed
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init))
    }
}
