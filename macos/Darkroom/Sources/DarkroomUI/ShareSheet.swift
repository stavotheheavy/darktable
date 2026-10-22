import SwiftUI
#if !os(macOS)
import UIKit

/// The system share sheet for a file: Save to Files, Photos, AirDrop, Mail and the rest.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension View {
    /// Opens the share sheet when an export has finished; the Mac saves through its own panel instead.
    func shareExport(_ model: DarkroomModel) -> some View {
        sheet(isPresented: Binding(get: { model.exportedFile != nil }, set: { if !$0 { model.exportedFile = nil } })) {
            if let url = model.exportedFile {
                ActivityView(url: url).presentationDetents([.medium, .large])
            }
        }
    }
}
#else
extension View {
    func shareExport(_ model: DarkroomModel) -> some View { self }
}
#endif
