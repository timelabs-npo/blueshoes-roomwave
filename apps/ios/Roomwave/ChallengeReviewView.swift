import SwiftUI
import UIKit

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ChallengeReviewView: View {
    let review: ChallengeReview
    @Environment(\.dismiss) private var dismiss
    @State private var exportFile: ExportFile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review the exact local JSON below before opening the system share sheet.")
                Text("Contains finalized stylized track, rules and content ID. No raw scan, camera frames or local capture IDs. Derived geometry is not guaranteed anonymous.")
                    .font(.footnote)
                ScrollView {
                    Text(String(decoding: review.data, as: UTF8.self))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button("Export reviewed JSON…") { export() }
                    .buttonStyle(.borderedProminent)
                Text("Choose a destination yourself. A selected share extension may send the file using that service; Roomwave implements no upload or public URL.")
                    .font(.footnote)
            }
            .padding()
            .navigationTitle("Challenge review")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $exportFile, onDismiss: removeTemporaryFile) { file in
                ActivitySheet(url: file.url)
            }
        }
    }

    @State private var temporaryURL: URL?

    private func export() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Roomwave-\(UUID().uuidString).json")
            try review.data.write(to: url, options: [.atomic, .completeFileProtection])
            temporaryURL = url
            exportFile = ExportFile(url: url)
        } catch { errorMessage = "Could not create local export: \(error)" }
    }

    private func removeTemporaryFile() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: 1, y: 1, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
