import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Pairwise export")
struct PairwiseExportTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("CSV has the stable schema and preserves canonical A minus B semantics")
    func csvSchemaAndValues() throws {
        let observation = makeObservation(
            sourceA: "alpha",
            sourceB: "zulu",
            valueA: 70.5,
            valueB: 77,
            sampleCountA: 3,
            sampleCountB: 2,
            standardDeviationA: 1.25,
            standardDeviationB: 0.5,
            provenanceA: .derived,
            provenanceB: .measured,
            severity: .notable
        )
        let analysis = makeAnalysis(
            sourceA: "alpha",
            sourceB: "zulu",
            observations: [observation],
            candidateWindowCount: 2,
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(id: "zulu", name: "Zulu Ring", transport: .oura, model: "Ring 4"),
                source(id: "alpha", name: "Alpha Strap", transport: .bluetooth, model: "H10"),
            ],
            appVersion: "1.2.3",
            generatedAt: base
        )

        let rows = try parseRFC4180(export.csv)
        #expect(rows.count == 2)
        #expect(rows[0] == PairwiseExporter.csvColumns)
        #expect(rows[1].count == PairwiseExporter.csvColumns.count)

        let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        #expect(row["window_start_utc"] == "2023-11-14T22:13:20.000Z")
        #expect(row["window_end_utc"] == "2023-11-14T22:14:20.000Z")
        #expect(row["metric"] == "heartRate")
        #expect(row["unit"] == "bpm")
        #expect(row["source_a_id"] == "alpha")
        #expect(row["source_a_name"] == "Alpha Strap")
        #expect(row["source_a_transport"] == "bluetooth")
        #expect(row["source_a_model"] == "H10")
        #expect(row["source_a_value"] == "70.5")
        #expect(row["source_a_sample_count"] == "3")
        #expect(row["source_a_within_window_sd"] == "1.25")
        #expect(row["source_a_provenance"] == "derived")
        #expect(row["source_b_id"] == "zulu")
        #expect(row["source_b_name"] == "Zulu Ring")
        #expect(row["source_b_transport"] == "oura")
        #expect(row["source_b_model"] == "Ring 4")
        #expect(row["source_b_value"] == "77")
        #expect(row["source_b_sample_count"] == "2")
        #expect(row["source_b_within_window_sd"] == "0.5")
        #expect(row["source_b_provenance"] == "measured")
        #expect(row["paired_mean"] == "73.75")
        #expect(row["signed_difference_a_minus_b"] == "-6.5")
        #expect(row["absolute_difference"] == "6.5")
        #expect(row["severity"] == "notable")
    }

    @Test("CSV applies RFC escaping to commas, quotes, CR, and LF")
    func csvEscaping() throws {
        let observation = makeObservation(
            sourceA: "a",
            sourceB: "b",
            valueA: 36.75,
            valueB: 37,
            severity: .agreeing
        )
        let analysis = makeAnalysis(
            kind: .bodyTemperature,
            sourceA: "a",
            sourceB: "b",
            observations: [observation],
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(
                    id: "a",
                    name: "Alpha, \"Chest\"\nStrap",
                    transport: .bluetooth,
                    model: "Model\r\nOne"
                ),
                source(id: "b", name: "Beta", transport: .healthKit, model: nil),
            ],
            appVersion: "1.0",
            generatedAt: base
        )

        let rows = try parseRFC4180(export.csv)
        #expect(rows.count == 2)
        #expect(rows[1][5] == "Alpha, \"Chest\"\nStrap")
        #expect(rows[1][7] == "Model\r\nOne")
        #expect(rows[1][3] == "°C")
        #expect(export.csv.contains("\"Alpha, \"\"Chest\"\"\nStrap\""))
        #expect(export.csv.contains("\"Model\r\nOne\""))
        #expect(export.csv.hasSuffix("\r\n"))
    }

    @Test("Compacted medians never masquerade as one raw sample with zero spread")
    func compactedUnknownEvidence() throws {
        let observation = makeObservation(
            sourceA: "alpha",
            sourceB: "beta",
            valueA: 70,
            valueB: 72,
            sampleCountA: nil,
            sampleCountB: 4,
            standardDeviationA: nil,
            standardDeviationB: 1.5,
            compactedA: true
        )
        let analysis = makeAnalysis(
            sourceA: "alpha",
            sourceB: "beta",
            observations: [observation],
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(id: "alpha", name: "Alpha"),
                source(id: "beta", name: "Beta"),
            ],
            appVersion: "1.0 (1)",
            generatedAt: base
        )
        let rows = try parseRFC4180(export.csv)
        let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))

        #expect(row["source_a_sample_count"] == "")
        #expect(row["source_a_within_window_sd"] == "")
        #expect(row["source_a_aggregation"] == "compacted_window_median")
        #expect(row["source_b_aggregation"] == "raw")
        #expect(analysis.rawSampleCountA == nil)
        #expect(export.summary.contains("Original samples contributing: A unknown (compacted history), B 4"))
        #expect(export.summary.contains("cannot accept later corrections or upstream deletions"))
    }

    @Test("Formula-leading source metadata is exported as literal spreadsheet text")
    func spreadsheetFormulaMetadataIsNeutralized() throws {
        let observation = makeObservation(sourceA: "a", sourceB: "b", valueA: 70, valueB: 71)
        let analysis = makeAnalysis(
            sourceA: "a",
            sourceB: "b",
            observations: [observation],
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(id: "a", name: "=SUM(1,1)", transport: .bluetooth, model: "+model"),
                source(id: "b", name: "\t-42", transport: .healthKit, model: "\u{0001}@model"),
            ],
            appVersion: "1.0",
            generatedAt: base
        )

        let rows = try parseRFC4180(export.csv)
        let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        #expect(row["source_a_name"] == "'=SUM(1,1)")
        #expect(row["source_a_model"] == "'+model")
        #expect(row["source_b_name"] == "' -42")
        #expect(row["source_b_model"] == "' @model")
    }

    @Test("No-overlap summary explicitly withholds an agreement conclusion")
    func noOverlapSummary() throws {
        let analysis = makeAnalysis(
            sourceA: "a",
            sourceB: "b",
            observations: [],
            candidateWindowCount: 2,
            state: .noOverlap
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [source(id: "a", name: "A"), source(id: "b", name: "B")],
            appVersion: "1.0",
            generatedAt: base
        )

        #expect(export.summary.contains("Evidence state: No overlap"))
        #expect(export.summary.contains("Conclusion withheld: no agreement conclusion is available"))
        #expect(!export.summary.contains("Severity: In agreement"))
        #expect(try parseRFC4180(export.csv).count == 1)
    }

    @Test("Collecting summary exports observations but withholds conclusions")
    func collectingSummary() throws {
        let observations = [
            makeObservation(sourceA: "a", sourceB: "b", valueA: 70, valueB: 70),
            makeObservation(index: 1, sourceA: "a", sourceB: "b", valueA: 71, valueB: 71),
        ]
        let analysis = makeAnalysis(
            sourceA: "a",
            sourceB: "b",
            observations: observations,
            candidateWindowCount: 4,
            state: .collecting(pairedWindowCount: 2, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [source(id: "a", name: "A"), source(id: "b", name: "B")],
            appVersion: "1.0",
            generatedAt: base
        )

        #expect(export.summary.contains("Evidence state: Collecting (2 of 5 paired windows)"))
        #expect(export.summary.contains("Conclusion withheld: insufficient evidence"))
        #expect(export.summary.contains("Agreement conclusions require at least 5 paired windows"))
        #expect(!export.summary.contains("Severity: In agreement"))
        #expect(try parseRFC4180(export.csv).count == 3)
    }

    @Test("Ready summary includes context, sample statistics, tolerances, and limitations")
    func readySummary() {
        let observations = (0..<5).map { index in
            makeObservation(
                index: index,
                sourceA: "alpha",
                sourceB: "beta",
                valueA: 70 + Double(index),
                valueB: 78 + Double(index),
                sampleCountA: 2,
                sampleCountB: 3,
                severity: .notable
            )
        }
        let statistics = PairwiseSummaryStatistics(
            meanBias: -8,
            meanAbsoluteDifference: 8,
            differenceSD: 1.25,
            limitsOfAgreement: -10.45 ... -5.55,
            severity: .notable,
            classification: .systematicBias
        )
        let analysis = makeAnalysis(
            sourceA: "alpha",
            sourceB: "beta",
            observations: observations,
            candidateWindowCount: 8,
            state: .ready(statistics)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(id: "beta", name: "Beta Watch", transport: .healthKit, model: "Watch 9"),
                source(id: "alpha", name: "Alpha Strap", transport: .bluetooth, model: "H10"),
            ],
            appVersion: "1.2.3 (45)",
            generatedAt: base
        )

        #expect(export.summary.contains("App version: 1.2.3 (45)"))
        #expect(export.summary.contains("Generated at (UTC): 2023-11-14T22:13:20.000Z"))
        #expect(export.summary.contains("Selected range (UTC):"))
        #expect(export.summary.contains("Source A: Alpha Strap"))
        #expect(export.summary.contains("Source B: Beta Watch"))
        #expect(export.summary.contains("Overlap: 62.5%"))
        #expect(export.summary.contains("Original samples contributing: A 10, B 15"))
        #expect(export.summary.contains("Mean bias (A - B): -8 bpm"))
        #expect(export.summary.contains("Sample standard deviation of differences: 1.25 bpm"))
        #expect(export.summary.contains("95% limits of agreement: -10.45 to -5.55 bpm"))
        #expect(export.summary.contains("Severity: Notable gap"))
        #expect(export.summary.contains("Pattern classification: Systematic bias"))
        #expect(export.summary.contains("sample standard deviation (n - 1)"))
        #expect(export.summary.contains("Notable gap: absolute difference at or above 5 bpm"))
        #expect(export.summary.contains("not a test of statistical significance"))
        #expect(export.summary.contains("Neither source is treated as a medical reference"))
        #expect(!export.summary.contains("Conclusion withheld"))
    }

    @Test("Metadata order cannot change output and unrelated sources cannot leak")
    func deterministicMetadataIsolation() {
        let observations = [makeObservation(sourceA: "a", sourceB: "b", valueA: 70, valueB: 75)]
        let analysis = makeAnalysis(
            sourceA: "a",
            sourceB: "b",
            observations: observations,
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let a = source(id: "a", name: "Alpha")
        let b = source(id: "b", name: "Beta")
        let unrelated = source(id: "unrelated", name: "oauth_access_token=SUPER_SECRET")

        let first = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [unrelated, b, a],
            appVersion: "1.0",
            generatedAt: base
        )
        let second = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [a, b, unrelated],
            appVersion: "1.0",
            generatedAt: base
        )

        #expect(first == second)
        #expect(!first.csv.contains("SUPER_SECRET"))
        #expect(!first.summary.contains("SUPER_SECRET"))
        #expect(!first.csvFilename.contains("SUPER_SECRET"))
        #expect(!first.summaryFilename.contains("SUPER_SECRET"))
    }

    @Test("UTC filenames are safe and artifacts are UTF-8")
    func safeFilenamesAndUTF8Data() {
        let sourceAID = "alpha/../../device"
        let sourceBID = "beta\\device:two"
        let observation = makeObservation(
            sourceA: sourceAID,
            sourceB: sourceBID,
            valueA: 70,
            valueB: 71
        )
        let analysis = makeAnalysis(
            sourceA: sourceAID,
            sourceB: sourceBID,
            observations: [observation],
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [
                source(id: sourceAID, name: "Alphá"),
                source(id: sourceBID, name: "Béta"),
            ],
            appVersion: "1.0",
            generatedAt: base
        )

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        #expect(export.csvFilename.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(export.summaryFilename.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(!export.csvFilename.contains(".."))
        #expect(!export.summaryFilename.contains(".."))
        #expect(export.csvFilename.contains("20231114T221320Z"))
        #expect(export.csvFilename.hasSuffix(".csv"))
        #expect(export.summaryFilename.hasSuffix("-summary.txt"))
        #expect(String(data: export.csvData, encoding: .utf8) == export.csv)
        #expect(String(data: export.summaryData, encoding: .utf8) == export.summary)
    }

    @Test("Missing historical source metadata falls back to stable source IDs")
    func missingMetadataFallback() throws {
        let observation = makeObservation(sourceA: "removed-a", sourceB: "removed-b", valueA: 70, valueB: 72)
        let analysis = makeAnalysis(
            sourceA: "removed-a",
            sourceB: "removed-b",
            observations: [observation],
            state: .collecting(pairedWindowCount: 1, requiredWindowCount: 5)
        )
        let export = PairwiseExporter.makeExport(
            analysis: analysis,
            sources: [],
            appVersion: "1.0",
            generatedAt: base
        )

        let rows = try parseRFC4180(export.csv)
        let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
        #expect(row["source_a_id"] == "removed-a")
        #expect(row["source_a_name"] == "removed-a")
        #expect(row["source_a_transport"]?.isEmpty == true)
        #expect(row["source_b_id"] == "removed-b")
        #expect(row["source_b_name"] == "removed-b")
        #expect(export.summary.contains("Transport: Unknown"))
        #expect(export.summary.contains("Model: Unknown"))
    }

    // MARK: - Fixtures

    private func makeObservation(
        index: Int = 0,
        sourceA: String,
        sourceB: String,
        valueA: Double,
        valueB: Double,
        sampleCountA: Int? = 1,
        sampleCountB: Int? = 1,
        standardDeviationA: Double? = 0,
        standardDeviationB: Double? = 0,
        provenanceA: Provenance = .measured,
        provenanceB: Provenance = .measured,
        compactedA: Bool = false,
        compactedB: Bool = false,
        severity: DiscrepancySeverity = .agreeing
    ) -> PairwiseObservation {
        PairwiseObservation(
            start: base.addingTimeInterval(Double(index) * 60),
            duration: 60,
            sourceA: SourceValue(
                sourceID: sourceA,
                value: valueA,
                sampleCount: sampleCountA,
                standardDeviation: standardDeviationA,
                provenance: provenanceA,
                isCompacted: compactedA
            ),
            sourceB: SourceValue(
                sourceID: sourceB,
                value: valueB,
                sampleCount: sampleCountB,
                standardDeviation: standardDeviationB,
                provenance: provenanceB,
                isCompacted: compactedB
            ),
            severity: severity
        )
    }

    private func makeAnalysis(
        kind: MetricKind = .heartRate,
        sourceA: String,
        sourceB: String,
        observations: [PairwiseObservation],
        candidateWindowCount: Int? = nil,
        state: PairwiseAnalysisState
    ) -> PairwiseAnalysis {
        let count = observations.count
        let candidates = candidateWindowCount ?? count
        let knownCountsA = observations.compactMap(\.sourceA.sampleCount)
        let knownCountsB = observations.compactMap(\.sourceB.sampleCount)
        let sampleCountA = knownCountsA.count == observations.count ? knownCountsA.reduce(0, +) : nil
        let sampleCountB = knownCountsB.count == observations.count ? knownCountsB.reduce(0, +) : nil
        let span = observations.first.flatMap { first in
            observations.last.map { DateInterval(start: first.start, end: $0.end) }
        }

        return PairwiseAnalysis(
            kind: kind,
            sourceA: sourceA,
            sourceB: sourceB,
            range: DateInterval(start: base.addingTimeInterval(-60), duration: 600),
            windowSize: 60,
            observations: observations,
            candidateWindowCount: candidates,
            pairedWindowCount: count,
            overlapPercentage: candidates == 0 ? 0 : Double(count) / Double(candidates) * 100,
            analyzedSpan: span,
            rawSampleCountA: sampleCountA,
            rawSampleCountB: sampleCountB,
            state: state
        )
    }

    private func source(
        id: String,
        name: String,
        transport: SourceTransport = .manual,
        model: String? = nil
    ) -> DataSource {
        DataSource(
            id: id,
            displayName: name,
            transport: transport,
            model: model,
            addedAt: base
        )
    }

    /// Minimal RFC 4180 reader used to assert exported values without relying on naive
    /// comma/newline splitting (which would hide escaping regressions).
    ///
    /// Scanning is done over unicode scalars, not `Character`s: Swift treats CR LF as a
    /// single grapheme cluster, so a `Character`-based scanner never matches a bare "\r"
    /// and silently swallows every record separator.
    private func parseRFC4180(_ csv: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(csv.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r":
                    guard index + 1 < scalars.count, scalars[index + 1] == "\n" else {
                        throw CSVParseError.invalidLineEnding
                    }
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                    index += 2
                    continue
                case "\n":
                    throw CSVParseError.invalidLineEnding
                default:
                    field.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }

        guard !inQuotes else { throw CSVParseError.unterminatedQuotedField }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private enum CSVParseError: Error {
        case invalidLineEnding
        case unterminatedQuotedField
    }
}
