import SwiftUI
import UniformTypeIdentifiers

// MARK: - DocumentPicker

struct DocumentPicker: UIViewControllerRepresentable {
    var kind: PickerKind
    var onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.item]
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ p: DocumentPicker) { parent = p }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            parent.onPick(u)
        }
    }
}

struct CertificateDocumentPicker: UIViewControllerRepresentable {
    let kind: CertificatePickerKind
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType]
        switch kind {
        case .p12:
            types = [.pkcs12]
        case .prov:
            types = [UTType(filenameExtension: "mobileprovision")!]  // Custom UTType for .mobileprovision
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)  // Import mode: copies file, no scope needed
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}

// MARK: - ActivityView

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}