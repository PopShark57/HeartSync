import Foundation
import SwiftUI

/// Every physiological quantity HeartSync can hold, regardless of which device produced it.
///
/// A metric owns its own units, formatting, plausible range, and — importantly for this app —
/// the thresholds at which two devices disagreeing becomes *interesting*. Those thresholds are
/// not arbitrary: see `agreement` for the reasoning behind each one.
enum MetricKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case heartRate
    case restingHeartRate
    case hrvSDNN
    case hrvRMSSD
    case spo2
    case respiratoryRate
    case bodyTemperature
    case vo2Max
    case bloodPressureSystolic
    case bloodPressureDiastolic

    var id: String { rawValue }

    /// Full metric name **for the screen**.
    ///
    /// Localized. Every English `defaultValue` here is byte-identical to `exportTitle`, and
    /// that is the only relationship the two properties have: this one follows the reader's
    /// language, `exportTitle` never does. Anything written into a file, a filename, or a
    /// comparison against a literal must use `exportTitle` instead.
    var title: String {
        switch self {
        case .heartRate:
            String(localized: "metric.title.heartRate", defaultValue: "Heart Rate", comment: "Full metric name for heart rate")
        case .restingHeartRate:
            String(localized: "metric.title.restingHeartRate", defaultValue: "Resting Heart Rate", comment: "Full metric name for resting heart rate")
        case .hrvSDNN:
            String(localized: "metric.title.hrvSDNN", defaultValue: "HRV (SDNN)", comment: "Full metric name for heart-rate variability measured as SDNN. HRV and SDNN are international abbreviations and are not translated.")
        case .hrvRMSSD:
            String(localized: "metric.title.hrvRMSSD", defaultValue: "HRV (RMSSD)", comment: "Full metric name for heart-rate variability measured as RMSSD. HRV and RMSSD are international abbreviations and are not translated.")
        case .spo2:
            String(localized: "metric.title.spo2", defaultValue: "Blood Oxygen", comment: "Full metric name for blood oxygen saturation")
        case .respiratoryRate:
            String(localized: "metric.title.respiratoryRate", defaultValue: "Respiratory Rate", comment: "Full metric name for respiratory rate, in breaths per minute")
        case .bodyTemperature:
            String(localized: "metric.title.bodyTemperature", defaultValue: "Body Temperature", comment: "Full metric name for body temperature")
        case .vo2Max:
            String(localized: "metric.title.vo2Max", defaultValue: "VO\u{2082} Max", comment: "Full metric name for maximal oxygen uptake. VO2 is an international abbreviation and is not translated; the 2 is a subscript.")
        case .bloodPressureSystolic:
            String(localized: "metric.title.bloodPressureSystolic", defaultValue: "Blood Pressure (Systolic)", comment: "Full metric name for the systolic half of a blood-pressure pair")
        case .bloodPressureDiastolic:
            String(localized: "metric.title.bloodPressureDiastolic", defaultValue: "Blood Pressure (Diastolic)", comment: "Full metric name for the diastolic half of a blood-pressure pair")
        }
    }

    /// Full metric name **for exports**, in English regardless of the device language.
    ///
    /// `PairwiseExporter` interpolates it into the plain-text summary
    /// ("Metric: Heart Rate (bpm)"), which `PairwiseExportTests` pins as a stable
    /// machine-readable artefact: an analysis exported on a Japanese phone must be the same
    /// bytes as one exported on an English phone, so a reviewer can diff two users' files.
    /// Never show this on screen — `title` exists for that.
    var exportTitle: String {
        switch self {
        case .heartRate:             "Heart Rate"
        case .restingHeartRate:      "Resting Heart Rate"
        case .hrvSDNN:               "HRV (SDNN)"
        case .hrvRMSSD:              "HRV (RMSSD)"
        case .spo2:                  "Blood Oxygen"
        case .respiratoryRate:       "Respiratory Rate"
        case .bodyTemperature:       "Body Temperature"
        case .vo2Max:                "VO\u{2082} Max"
        case .bloodPressureSystolic: "Blood Pressure (Systolic)"
        case .bloodPressureDiastolic:"Blood Pressure (Diastolic)"
        }
    }

    /// Abbreviated metric name for chips, legends, and other space-constrained labels.
    ///
    /// Localized because it is a plain `String` and so is never extracted the way a SwiftUI
    /// `Text` literal is. Unlike `title` and `unit` this abbreviation never reaches
    /// `PairwiseExporter`, so translating it cannot destabilise the export format.
    var shortTitle: String {
        switch self {
        case .heartRate:
            String(localized: "metric.short.heartRate", defaultValue: "HR", comment: "Abbreviated metric name for heart rate")
        case .restingHeartRate:
            String(localized: "metric.short.restingHeartRate", defaultValue: "RHR", comment: "Abbreviated metric name for resting heart rate")
        case .hrvSDNN:
            String(localized: "metric.short.hrvSDNN", defaultValue: "SDNN", comment: "Abbreviated metric name for heart-rate variability measured as SDNN")
        case .hrvRMSSD:
            String(localized: "metric.short.hrvRMSSD", defaultValue: "RMSSD", comment: "Abbreviated metric name for heart-rate variability measured as RMSSD")
        case .spo2:
            String(localized: "metric.short.spo2", defaultValue: "SpO\u{2082}", comment: "Abbreviated metric name for blood oxygen saturation")
        case .respiratoryRate:
            String(localized: "metric.short.respiratoryRate", defaultValue: "Resp", comment: "Abbreviated metric name for respiratory rate")
        case .bodyTemperature:
            String(localized: "metric.short.bodyTemperature", defaultValue: "Temp", comment: "Abbreviated metric name for body temperature")
        case .vo2Max:
            String(localized: "metric.short.vo2Max", defaultValue: "VO\u{2082}", comment: "Abbreviated metric name for VO2 max")
        case .bloodPressureSystolic:
            String(localized: "metric.short.bloodPressureSystolic", defaultValue: "SYS", comment: "Abbreviated metric name for systolic blood pressure")
        case .bloodPressureDiastolic:
            String(localized: "metric.short.bloodPressureDiastolic", defaultValue: "DIA", comment: "Abbreviated metric name for diastolic blood pressure")
        }
    }

    /// Unit symbol **for the screen**.
    ///
    /// Localized, because "br/min" and "bpm" are English abbreviations that a reader of
    /// another language cannot expand. Keyed by the symbol rather than by the metric so the
    /// units several metrics share are translated once. The English `defaultValue`s are
    /// byte-identical to `exportUnit`.
    var unit: String {
        switch self {
        case .heartRate, .restingHeartRate:
            String(localized: "unit.bpm", defaultValue: "bpm", comment: "Unit symbol: beats per minute")
        case .hrvSDNN, .hrvRMSSD:
            String(localized: "unit.milliseconds", defaultValue: "ms", comment: "Unit symbol: milliseconds, the unit of heart-rate variability")
        case .spo2:
            String(localized: "unit.percent", defaultValue: "%", comment: "Unit symbol: percent, used for blood oxygen saturation")
        case .respiratoryRate:
            String(localized: "unit.breathsPerMinute", defaultValue: "br/min", comment: "Unit symbol: breaths per minute")
        case .bodyTemperature:
            String(localized: "unit.celsius", defaultValue: "\u{00B0}C", comment: "Unit symbol: degrees Celsius. HeartSync stores and shows temperature in Celsius only, so do not substitute a Fahrenheit symbol.")
        case .vo2Max:
            String(localized: "unit.millilitresPerKilogramPerMinute", defaultValue: "mL/kg\u{00B7}min", comment: "Unit symbol for VO2 max: millilitres of oxygen per kilogram of body mass per minute")
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            String(localized: "unit.mmHg", defaultValue: "mmHg", comment: "Unit symbol: millimetres of mercury, the unit of blood pressure. This symbol is international and is normally left untranslated.")
        }
    }

    /// Unit symbol **for exports**, in English regardless of the device language.
    ///
    /// This is the literal value of the export's `unit` CSV column, pinned by
    /// `PairwiseExportTests` (`row["unit"] == "bpm"`, `rows[1][3] == "°C"`), and it is also
    /// the unit suffixed to every statistic in the text summary. A translated symbol here
    /// would change a machine-readable field of an already-published format, so a consumer
    /// parsing the CSV would have to know the exporting phone's language to read it.
    var exportUnit: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .hrvSDNN, .hrvRMSSD:           "ms"
        case .spo2:                         "%"
        case .respiratoryRate:              "br/min"
        case .bodyTemperature:              "\u{00B0}C"
        case .vo2Max:                       "mL/kg\u{00B7}min"
        case .bloodPressureSystolic, .bloodPressureDiastolic: "mmHg"
        }
    }

    var systemImage: String {
        switch self {
        case .heartRate, .restingHeartRate: "heart.fill"
        case .hrvSDNN, .hrvRMSSD:           "waveform.path.ecg"
        case .spo2:                         "lungs.fill"
        case .respiratoryRate:              "wind"
        case .bodyTemperature:              "thermometer.medium"
        case .vo2Max:                       "figure.run"
        case .bloodPressureSystolic, .bloodPressureDiastolic: "gauge.with.dots.needle.33percent"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate, .restingHeartRate: .pink
        case .hrvSDNN, .hrvRMSSD:           .purple
        case .spo2:                         .blue
        case .respiratoryRate:              .teal
        case .bodyTemperature:              .orange
        case .vo2Max:                       .green
        case .bloodPressureSystolic, .bloodPressureDiastolic: .red
        }
    }

    /// Decimal places to show. HR is an integer; temperature is not.
    var fractionDigits: Int {
        switch self {
        case .bodyTemperature: 1
        case .vo2Max:          1
        case .spo2:            0
        default:               0
        }
    }

    /// Physiologically plausible range. Values outside are rejected at ingest as sensor noise
    /// rather than being stored and then reported as a huge "discrepancy".
    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .heartRate:             20...250
        case .restingHeartRate:      25...140
        case .hrvSDNN:               1...400
        case .hrvRMSSD:              1...400
        case .spo2:                  50...100
        case .respiratoryRate:       4...60
        case .bodyTemperature:       30...45
        case .vo2Max:                10...95
        case .bloodPressureSystolic: 60...260
        case .bloodPressureDiastolic:30...180
        }
    }

    /// A nominal display range for charts, so a flat line doesn't fill the whole axis.
    var displayRange: ClosedRange<Double> {
        switch self {
        case .heartRate:             40...160
        case .restingHeartRate:      40...90
        case .hrvSDNN:               10...150
        case .hrvRMSSD:              10...150
        case .spo2:                  88...100
        case .respiratoryRate:       8...24
        case .bodyTemperature:       34...39
        case .vo2Max:                25...60
        case .bloodPressureSystolic: 90...160
        case .bloodPressureDiastolic:50...100
        }
    }

    /// How far two devices may drift apart before it is worth mentioning.
    ///
    /// - `heartRate`: two optical sensors on a still subject normally track within a few bpm;
    ///   8+ usually means one of them is motion-corrupted or locked onto a harmonic.
    /// - `spo2`: consumer pulse oximeters are specified to roughly \u{00B1}2% ARMS, so 3% is the
    ///   first point where the gap exceeds both devices' own stated accuracy.
    /// - `hrv*`: HRV is the *least* comparable metric across vendors — different windows,
    ///   different artefact correction, different sampling. Wide tolerances are honest here.
    var agreement: AgreementTolerance {
        switch self {
        case .heartRate:             .init(warn: 5,   alert: 12)
        case .restingHeartRate:      .init(warn: 4,   alert: 9)
        case .hrvSDNN:               .init(warn: 15,  alert: 35)
        case .hrvRMSSD:              .init(warn: 15,  alert: 35)
        case .spo2:                  .init(warn: 2,   alert: 4)
        case .respiratoryRate:       .init(warn: 2,   alert: 4)
        case .bodyTemperature:       .init(warn: 0.3, alert: 0.7)
        case .vo2Max:                .init(warn: 3,   alert: 7)
        case .bloodPressureSystolic: .init(warn: 8,   alert: 15)
        case .bloodPressureDiastolic:.init(warn: 5,   alert: 10)
        }
    }

    /// Metrics that stream continuously and belong on the live dashboard.
    var isContinuous: Bool {
        switch self {
        case .heartRate, .spo2, .hrvRMSSD, .respiratoryRate, .bodyTemperature: true
        default: false
        }
    }

    /// Time window used when bucketing samples for cross-device comparison.
    /// Fast-moving metrics need tight buckets; daily summaries need loose ones.
    var comparisonWindow: TimeInterval {
        switch self {
        case .heartRate, .spo2, .respiratoryRate, .bodyTemperature: 60
        case .hrvSDNN, .hrvRMSSD:                                   300
        case .restingHeartRate, .vo2Max:                            86_400
        case .bloodPressureSystolic, .bloodPressureDiastolic:       600
        }
    }

    func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// Screen copy: both halves follow the reader's locale — the number through
    /// `format(_:)`'s `FormatStyle`, the symbol through the localized `unit`. It feeds
    /// interpretation sentences and accessibility labels, never an export. The exporter
    /// composes its own value and `exportUnit` so its bytes stay language-independent.
    func formatWithUnit(_ value: Double) -> String {
        "\(format(value)) \(unit)"
    }
}

/// Thresholds describing when a between-device difference stops being noise.
struct AgreementTolerance: Sendable, Hashable {
    /// Below this the devices are considered to agree.
    var warn: Double
    /// At or above this the gap is large enough that one reading is probably wrong.
    var alert: Double

    func severity(forDelta delta: Double) -> DiscrepancySeverity {
        let d = abs(delta)
        if d >= alert { return .major }
        if d >= warn  { return .notable }
        return .agreeing
    }
}
