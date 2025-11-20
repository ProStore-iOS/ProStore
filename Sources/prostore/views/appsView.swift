import SwiftUI
import Security

struct AppsView: View {
    @State private var certNames: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Certificate Info")
                .font(.largeTitle)
                .bold()

            if !certNames.isEmpty {
                ForEach(certNames, id: \.self) { name in
                    Text("• \(name)")
                        .font(.title3)
                }
            } else if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
            } else {
                Text("Loading…")
            }
        }
        .padding()
        .onAppear {
            loadCertificateNames()
        }
    }

    func loadCertificateNames() {
        guard let provPath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let provData = try? Data(contentsOf: URL(fileURLWithPath: provPath)),
              let provString = String(data: provData, encoding: .ascii) else {
            errorMessage = "No provisioning profile found."
            return
        }

        guard let start = provString.range(of: "<?xml"),
              let end = provString.range(of: "</plist>") else {
            errorMessage = "Invalid provisioning profile structure."
            return
        }

        let plistString = String(provString[start.lowerBound...end.upperBound])

        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let devCerts = plist["DeveloperCertificates"] as? [Data] else {
            errorMessage = "Couldn't read DeveloperCertificates."
            return
        }

        var names: [String] = []

        for certData in devCerts {
            if let cert = SecCertificateCreateWithData(nil, certData as CFData),
               let summary = SecCertificateCopySubjectSummary(cert) as String? {
                names.append(summary)
            }
        }

        if names.isEmpty {
            errorMessage = "No certificate names found."
        } else {
            certNames = names
        }
    }
}
