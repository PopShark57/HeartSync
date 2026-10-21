import SwiftUI

/// The Mac's counterpart of the iPhone's `UIActivityViewController` sheet: the exported
/// files, with Share and Save. The shared pair-analysis screen presents it by this name.
///
/// The files live in a per-export temporary folder that the presenting screen deletes when
/// this sheet closes (`ExportDirectory`), so Save moves them out first.
struct ReadingsShareSheet: View {
    var items: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.title2.weight(.semibold))
            ForEach(items, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc.text")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                ShareLink(items: items) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save…") { saving = true }
                    .keyboardShortcut(.defaultAction)
            }
            // The sheet's actions wait while the destination panel is open. That panel is drawn
            // by another process, so this is also how the UI smoke test sees that it opened.
            .disabled(saving)
        }
        .padding(20)
        .frame(minWidth: 420)
        .fileMover(isPresented: $saving, files: items) { result in
            switch result {
            case .success: dismiss()
            case .failure(let error): saveError = error.localizedDescription
            }
        }
    }
}
