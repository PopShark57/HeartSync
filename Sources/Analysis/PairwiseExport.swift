import Foundation

/// A deterministic, side-effect-free representation of a pairwise analysis export.
///
/// File creation and presentation belong to the UI layer. Keeping this value as strings
/// and UTF-8 data makes the export easy to test and prevents it from reaching into the
/// reading archive, settings, keychain, or any other unrelated state.
struct PairwiseExport: Hashable, Sendable {
    let csv: String
    let summary: String
    let csvFilename: String
    let summaryFilename: String

    var csvData: Data { Data(csv.utf8) }
    var summaryData: Data { Data(summary.utf8) }
}

/// Creates the two contextual artifacts for one metric and one ordered device pair.
enum PairwiseExporter {

    /// Stable, machine-readable CSV columns. Values for A and B always follow the
    /// canonical ordering in `PairwiseAnalysis`; the signed difference is therefore A - B.
    static let csvColumns = [
        "window_start_utc",
        "window_end_utc",
        "metric",
        "unit",
        "source_a_id",
        "source_a_name",
        "source_a_transport",
        "source_a_model",
        "source_a_value",
        "source_a_sample_count",
        "source_a_within_window_sd",
        "source_a_provenance",
        "source_b_id",
        "source_b_name",
        "source_b_transport",
        "source_b_model",
        "source_b_value",
        "source_b_sample_count",
        "source_b_within_window_sd",
        "source_b_provenance",
        "paired_mean",
        "signed_difference_a_minus_b",
        "absolute_difference",
        "severity",
    ]

    /// Builds CSV observations and a human-readable methodology/limitations summary.
    ///
    /// `sources` may contain the app's full source list, but only metadata matching the
    /// analysis pair is read or emitted. Missing metadata gracefully falls back to the
    /// stable source ID so an historical analysis remains exportable after device removal.
    static func makeExport(
        analysis: PairwiseAnalysis,
        sources: [DataSource],
        appVersion: String,
        generatedAt: Date
    ) -> PairwiseExport {
        let formatting = ExportFormatting()
        let sourceA = descriptor(for: analysis.sourceA, in: sources)
        let sourceB = descriptor(for: analysis.sourceB, in: sources)

        let csv = makeCSV(
            analysis: analysis,
            sourceA: sourceA,
            sourceB: sourceB,
            formatting: formatting
        )
        let summary = makeSummary(
            analysis: analysis,
            sourceA: sourceA,
            sourceB: sourceB,
            appVersion: appVersion,
            generatedAt: generatedAt,
            formatting: formatting
        )

        let filenameStem = [
            "HeartSync-pairwise",
            safeFilenameComponent(analysis.kind.rawValue),
            safeFilenameComponent(analysis.sourceA),
            "vs",
            safeFilenameComponent(analysis.sourceB),
            formatting.compactUTC(generatedAt),
        ].joined(separator: "-")

        return PairwiseExport(
            csv: csv,
            summary: summary,
            csvFilename: "\(filenameStem).csv",
            summaryFilename: "\(filenameStem)-summary.txt"
        )
    }

    // MARK: - CSV

    private static func makeCSV(
        analysis: PairwiseAnalysis,
        sourceA: SourceDescriptor,
        sourceB: SourceDescriptor,
        formatting: ExportFormatting
    ) -> String {
        var rows = [csvColumns.map(csvEscape).joined(separator: ",")]
        rows.reserveCapacity(analysis.observations.count + 1)

        for observation in analysis.observations {
            let fields = [
                formatting.iso8601UTC(observation.start),
                formatting.iso8601UTC(observation.end),
                analysis.kind.rawValue,
                analysis.kind.unit,
                sourceA.id,
                sourceA.name,
                sourceA.transportRawValue,
                sourceA.model,
                decimal(observation.sourceA.value),
                String(observation.sourceA.sampleCount),
                decimal(observation.sourceA.standardDeviation),
                observation.sourceA.provenance.rawValue,
                sourceB.id,
                sourceB.name,
                sourceB.transportRawValue,
                sourceB.model,
                decimal(observation.sourceB.value),
                String(observation.sourceB.sampleCount),
                decimal(observation.sourceB.standardDeviation),
                observation.sourceB.provenance.rawValue,
                decimal(observation.pairedMean),
                decimal(observation.signedDifference),
                decimal(observation.absoluteDifference),
                severityMachineValue(observation.severity),
            ]
            rows.append(fields.map(csvEscape).joined(separator: ","))
        }

        // RFC 4180 uses CRLF records. A final record delimiter also makes command-line
        // tools handle the last row consistently.
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a field when RFC 4180 requires it.
    ///
    /// The scan is over unicode scalars rather than `Character`s: Swift merges CR LF into
    /// one grapheme cluster, so `field.contains("\r")` is false for "a\r\nb" and the raw
    /// line break would be written unquoted, splitting one record into two.
    private static func csvEscape(_ field: String) -> String {
        let needsQuoting = field.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "\"" || scalar == "\r" || scalar == "\n"
        }
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Text summary

    private static func makeSummary(
        analysis: PairwiseAnalysis,
        sourceA: SourceDescriptor,
        sourceB: SourceDescriptor,
        appVersion: String,
        generatedAt: Date,
        formatting: ExportFormatting
    ) -> String {
        var lines = [
            "HeartSync Pairwise Analysis",
            "",
            "App version: \(singleLine(appVersion))",
            "Generated at (UTC): \(formatting.iso8601UTC(generatedAt))",
            "Metric: \(analysis.kind.title) (\(analysis.kind.unit))",
            "Selected range (UTC): \(formatting.iso8601UTC(analysis.range.start)) to \(formatting.iso8601UTC(analysis.range.end))",
            "Comparison window: \(durationDescription(analysis.windowSize))",
            "",
            "Ordered sources",
            "Source A: \(sourceA.summaryName)",
            "  ID: \(singleLine(sourceA.id))",
            "  Transport: \(sourceA.transportTitle)",
            "  Model: \(sourceA.summaryModel)",
            "Source B: \(sourceB.summaryName)",
            "  ID: \(singleLine(sourceB.id))",
            "  Transport: \(sourceB.transportTitle)",
            "  Model: \(sourceB.summaryModel)",
            "Signed differences use A minus B.",
            "",
            "Evidence",
            "Candidate windows: \(analysis.candidateWindowCount)",
            "Paired windows: \(analysis.pairedWindowCount)",
            "Overlap: \(decimal(analysis.overlapPercentage))%",
            "Raw samples contributing: A \(analysis.rawSampleCountA), B \(analysis.rawSampleCountB)",
            "Analyzed span (UTC): \(spanDescription(analysis.analyzedSpan, formatting: formatting))",
        ]

        switch analysis.state {
        case .noOverlap:
            lines += [
                "Evidence state: No overlap",
                "Conclusion withheld: no agreement conclusion is available because the devices have no overlapping comparison windows.",
            ]

        case let .collecting(pairedWindowCount, requiredWindowCount):
            lines += [
                "Evidence state: Collecting (\(pairedWindowCount) of \(requiredWindowCount) paired windows)",
                "Conclusion withheld: insufficient evidence. Agreement conclusions require at least \(requiredWindowCount) paired windows; this export contains only the observations available so far.",
            ]

        case let .ready(statistics):
            lines += [
                "Evidence state: Ready",
                "",
                "Descriptive results",
                "Mean bias (A - B): \(decimal(statistics.meanBias)) \(analysis.kind.unit)",
                "Mean absolute difference: \(decimal(statistics.meanAbsoluteDifference)) \(analysis.kind.unit)",
                "Sample standard deviation of differences: \(decimal(statistics.differenceSD)) \(analysis.kind.unit)",
                "95% limits of agreement: \(decimal(statistics.limitsOfAgreement.lowerBound)) to \(decimal(statistics.limitsOfAgreement.upperBound)) \(analysis.kind.unit)",
                "Severity: \(statistics.severity.title)",
                "Pattern classification: \(classificationTitle(statistics.classification))",
                "Interpretation: \(interpretation(for: statistics, kind: analysis.kind))",
            ]
        }

        lines += [
            "",
            "Fixed comparison tolerances",
            "Notable gap: absolute difference at or above \(decimal(analysis.kind.agreement.warn)) \(analysis.kind.unit)",
            "Major gap: absolute difference at or above \(decimal(analysis.kind.agreement.alert)) \(analysis.kind.unit)",
            "",
            "Methodology",
            "Readings are placed into Unix-epoch-aligned windows. Each source is represented by the median of its non-estimated, plausible samples in a window. Only windows containing both ordered sources are paired. The signed difference is A minus B. Ready analyses use the sample standard deviation (n - 1); 95% limits of agreement are mean bias plus or minus 1.96 times that standard deviation.",
            "",
            "Limitations",
            "This is a descriptive device comparison, not a test of statistical significance. Neither source is treated as a medical reference or identified as correct. Sampling schedules, sensor placement, motion, vendor processing, and a small number of paired windows can all affect the result. HeartSync is not a medical device; do not use this export to diagnose or treat a condition.",
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    private static func interpretation(
        for statistics: PairwiseSummaryStatistics,
        kind: MetricKind
    ) -> String {
        let pattern: String
        switch statistics.classification {
        case .noApparentDifference:
            pattern = "The paired values show no apparent difference at HeartSync's fixed \(kind.title.lowercased()) tolerance."
        case .systematicBias:
            pattern = "The differences are predominantly in one direction, which is descriptive of a consistent offset between the sources."
        case .measurementNoise:
            pattern = "The differences vary around their mean, which is descriptive of measurement variability rather than a consistent one-direction offset."
        }
        return pattern + " This does not establish which source is more accurate."
    }

    private static func classificationTitle(_ classification: PairwiseDifferenceClassification) -> String {
        switch classification {
        case .noApparentDifference: "No apparent difference"
        case .systematicBias: "Systematic bias"
        case .measurementNoise: "Measurement noise"
        }
    }

    // MARK: - Formatting and metadata isolation

    private static func descriptor(for sourceID: String, in sources: [DataSource]) -> SourceDescriptor {
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            return SourceDescriptor(
                id: sourceID,
                name: sourceID,
                transportRawValue: "",
                transportTitle: "Unknown",
                model: ""
            )
        }
        return SourceDescriptor(
            id: source.id,
            name: source.displayName,
            transportRawValue: source.transport.rawValue,
            transportTitle: source.transport.title,
            model: source.model ?? ""
        )
    }

    private static func severityMachineValue(_ severity: DiscrepancySeverity) -> String {
        switch severity {
        case .agreeing: "agreeing"
        case .notable: "notable"
        case .major: "major"
        }
    }

    private static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == 0 { return "0" } // Normalise negative zero.
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func durationDescription(_ duration: TimeInterval) -> String {
        if duration.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(decimal(duration / 86_400)) day(s)"
        }
        if duration.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(decimal(duration / 60)) minute(s)"
        }
        return "\(decimal(duration)) second(s)"
    }

    private static func spanDescription(
        _ span: DateInterval?,
        formatting: ExportFormatting
    ) -> String {
        guard let span else { return "Not available" }
        return "\(formatting.iso8601UTC(span.start)) to \(formatting.iso8601UTC(span.end))"
    }

    /// Flattens metadata onto one line so `Key: value` summary records stay parseable.
    /// CR LF splits into two empty-separated components, so empties are dropped rather
    /// than turned into a double space.
    fileprivate static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func safeFilenameComponent(_ raw: String) -> String {
        var result = ""
        var needsSeparator = false

        for scalar in raw.unicodeScalars {
            let isASCIILetter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            let isDigit = (48...57).contains(scalar.value)
            let isSafePunctuation = scalar == "-" || scalar == "_"

            if isASCIILetter || isDigit || isSafePunctuation {
                if needsSeparator, !result.isEmpty, !result.hasSuffix("-") {
                    result.append("-")
                }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "source" : String(trimmed.prefix(48))
    }
}

private struct SourceDescriptor {
    let id: String
    let name: String
    let transportRawValue: String
    let transportTitle: String
    let model: String

    var summaryName: String { PairwiseExporter.singleLine(name) }
    var summaryModel: String {
        model.isEmpty ? "Unknown" : PairwiseExporter.singleLine(model)
    }
}

private final class ExportFormatting {
    private let isoFormatter: ISO8601DateFormatter
    private let compactFormatter: DateFormatter

    init() {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.isoFormatter = isoFormatter

        let compactFormatter = DateFormatter()
        compactFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactFormatter.calendar = Calendar(identifier: .gregorian)
        compactFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        compactFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        self.compactFormatter = compactFormatter
    }

    func iso8601UTC(_ date: Date) -> String { isoFormatter.string(from: date) }
    func compactUTC(_ date: Date) -> String { compactFormatter.string(from: date) }
}
