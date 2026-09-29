import SwiftUI
import UIKit

/// `UIActivityViewController` for an exported readings file. UIKit only because SwiftUI
/// has no share sheet that accepts a file produced after the user asks for it.
struct ReadingsShareSheet: UIViewControllerRepresentable {
    var items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Progress of a running readings export, with the Cancel that stops it between pages.
struct ExportProgressRow: View {
    let job: ReadingsExportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = job.fractionComplete {
                ProgressView(value: fraction) {
                    Text("Preparing export\u{2026}")
                } currentValueLabel: {
                    Text("Rows written: \(job.written.formatted()) of \((job.total ?? 0).formatted())")
                        .monospacedDigit()
                }
            } else {
                ProgressView {
                    Text("Preparing export\u{2026}")
                }
            }
            Button("Cancel export", role: .cancel) { job.cancel() }
                .buttonStyle(.borderless)
                .accessibilityHint("Stops the export and deletes the partial file")
        }
        .accessibilityIdentifier("export.progress")
    }
}
