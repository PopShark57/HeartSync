import AppIntents

enum ComplicationMetric: String, AppEnum {
    case heartRate, restingHeartRate, hrvSDNN, hrvRMSSD, spo2, respiratoryRate, bodyTemperature

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Measurement")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .heartRate: "Heart Rate",
        .restingHeartRate: "Resting Heart Rate",
        .hrvSDNN: "HRV (SDNN)",
        .hrvRMSSD: "HRV (RMSSD)",
        .spo2: "Blood Oxygen",
        .respiratoryRate: "Respiratory Rate",
        .bodyTemperature: "Body Temperature",
    ]

    var kind: MetricKind {
        switch self {
        case .heartRate: .heartRate
        case .restingHeartRate: .restingHeartRate
        case .hrvSDNN: .hrvSDNN
        case .hrvRMSSD: .hrvRMSSD
        case .spo2: .spo2
        case .respiratoryRate: .respiratoryRate
        case .bodyTemperature: .bodyTemperature
        }
    }
}

struct MeasurementIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "HeartSync Measurement"
    static let description = IntentDescription("Choose a measurement synced from HeartSync on iPhone.")

    @Parameter(title: "Measurement", default: .heartRate)
    var metric: ComplicationMetric

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$metric)")
    }

    init() {}

    init(metric: ComplicationMetric) {
        self.metric = metric
    }
}
