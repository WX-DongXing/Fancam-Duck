import SwiftUI
import UniformTypeIdentifiers

/// The system copies the existing movie to the chosen destination; no whole-movie Data buffer.
struct SaveVideoPicker:UIViewControllerRepresentable {
    let url:URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator {Coordinator {dismiss()}}
    func makeUIViewController(context:Context) -> UIDocumentPickerViewController {
        let picker=UIDocumentPickerViewController(forExporting:[url],asCopy:true)
        picker.delegate=context.coordinator;return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator:NSObject,UIDocumentPickerDelegate {
        let finish:()->Void
        init(finish:@escaping ()->Void) {self.finish=finish}
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {finish()}
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {finish()}
    }
}
