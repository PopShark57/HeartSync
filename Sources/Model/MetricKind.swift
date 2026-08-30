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

    var title: String {
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

    var shortTitle: String {
        switch self {
        case .heartRate:             "HR"
        case .restingHeartRate:      "RHR"
        case .hrvSDNN:               "SDNN"
        case .hrvRMSSD:              "RMSSD"
        case .spo2:                  "SpO\u{2082}"
        case .respiratoryRate:       "Resp"
        case .bodyTemperature:       "Temp"
        case .vo2Max:                "VO\u{2082}"
        case .bloodPressureSystolic: "SYS"
        case .bloodPressureDiastolic:"DIA"
        }
    }

    var unit: String {
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
