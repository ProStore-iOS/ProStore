import SwiftUI
import UniformTypeIdentifiers
import ProStoreTools

struct SignerView: View {
    @StateObject private var ipa = FileItem()
    @State private var isProcessing = false
    @State private var overallProgress: Double = 0.0
    @State private var currentStage: String = ""
    @State private var barColor: Color = .blue
    @State private var isError: Bool = false
    @State private var errorDetails: String = ""
    @State private var showActivity = false
    @State private var activityURL: URL? = nil
    @State private var showPickerFor: PickerKind? = nil
    @State private var selectedCertificateName: String? = nil
    @State private var expireStatus: String = "Unknown"
    @State private var hasSelectedCertificate: Bool = false

    var body: some View {
        Form {
            Section(header: Text("Inputs")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.top, 8)) {
                // IPA picker with icon and truncated file name
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                    Text("IPA")
                    Spacer()
                    Text(ipa.name.isEmpty ? "No file selected selected" : ipa.name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                    Button(action: {
                        showPickerFor = .ipa
                    }) {
                        Text("Pick")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                .padding(.vertical, 4)
                if hasSelectedCertificate, let name = selectedCertificateName {
                    Text("The \(name) certificate (\(expireStatus)) will be used to sign the ipa file. If you wish to use a different certificate for signing, please select or add it to the certificates page.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    Text("No certificate selected. Please add and select one in the Certificates tab.")
                        .foregroundColor(.red)
                        .padding(.vertical, 4)
                }
            }
            Section {
                Button(action: runSign) {
                    HStack {
                        Spacer()
                        Text("Sign IPA")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(isProcessing || ipa.url == nil || !hasSelectedCertificate ? Color.gray : Color.blue)
                            .cornerRadius(10)
                            .shadow(radius: 2)
                        Spacer()
                    }
                }
                .disabled(isProcessing || ipa.url == nil || !hasSelectedCertificate)
                .scaleEffect(isProcessing ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isProcessing)
            }
            .padding(.vertical, 8)
            if isProcessing || !currentStage.isEmpty {
                Section(header: Text("Progress")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .padding(.top, 8)) {
                    HStack {
                        Text(currentStage)
                            .foregroundColor(currentStage == "Error" ? .red : currentStage == "Done!" ? .green : .primary)
                            .animation(.easeInOut(duration: 0.2), value: currentStage)
                        ProgressView(value: overallProgress)
                            .progressViewStyle(.linear)
                            .tint(barColor)
                            .frame(maxWidth: .infinity)
                            .animation(.easeInOut(duration: 0.5), value: overallProgress)
                            .animation(.default, value: barColor)
                        Text("\(Int(overallProgress * 100))%")
                            .foregroundColor(currentStage == "Error" ? .red : currentStage == "Done!" ? .green : .primary)
                            .animation(nil, value: overallProgress)
                    }
                    if isError {
                        Text(errorDetails)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
        }
        .accentColor(.blue)
        .sheet(item: $showPickerFor, onDismiss: nil) { kind in
            DocumentPicker(kind: kind, onPick: { url in
                switch kind {
                case .ipa:
                    ipa.url = url
                default:
                    break
                }
            })
        }
        .sheet(isPresented: $showActivity) {
            if let u = activityURL {
                ActivityView(url: u)
            } else {
                Text("No file to share")
                    .foregroundColor(.red)
            }
        }
        .onAppear {
            loadSelectedCertificate()
        }
    }

    private func loadSelectedCertificate() {
        guard let selectedFolder = UserDefaults.standard.string(forKey: "selectedCertificateFolder") else {
            hasSelectedCertificate = false
            return
        }
        let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(selectedFolder)
        do {
            if let nameData = try? Data(contentsOf: certDir.appendingPathComponent("name.txt")),
               let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                selectedCertificateName = name
            } else {
                selectedCertificateName = "Custom Certificate"
            }
            let provURL = certDir.appendingPathComponent("profile.mobileprovision")
            if let expiry = ProStoreTools.getExpirationDate(provURL: provURL) {
                let now = Date()
                let components = Calendar.current.dateComponents([.day], from: now, to: expiry)
                let days = components.day ?? 0
                switch days {
                case ..<0, 0:
                    expireStatus = "Expired"
                case 1...30:
                    expireStatus = "Expiring Soon"
                default:
                    expireStatus = "Valid"
                }
            } else {
                expireStatus = "Unknown"
            }
            hasSelectedCertificate = true
        } catch {
            hasSelectedCertificate = false
            selectedCertificateName = nil
            expireStatus = "Unknown"
        }
    }

    func runSign() {
        guard let ipaURL = ipa.url else {
            currentStage = "Error"
            errorDetails = "Pick IPA file first 😅"
            isError = true
            withAnimation {
                overallProgress = 1.0
                barColor = .red
            }
            return
        }
        guard let selectedFolder = UserDefaults.standard.string(forKey: "selectedCertificateFolder") else {
            currentStage = "Error"
            errorDetails = "No certificate selected 😅"
            isError = true
            withAnimation {
                overallProgress = 1.0
                barColor = .red
            }
            return
        }
        let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(selectedFolder)
        let p12URL = certDir.appendingPathComponent("certificate.p12")
        let provURL = certDir.appendingPathComponent("profile.mobileprovision")
        let passwordURL = certDir.appendingPathComponent("password.txt")
        guard FileManager.default.fileExists(atPath: p12URL.path), FileManager.default.fileExists(atPath: provURL.path) else {
            currentStage = "Error"
            errorDetails = "Error loading certificate files 😅"
            isError = true
            withAnimation {
                overallProgress = 1.0
                barColor = .red
            }
            return
        }
        let p12Password: String
        if let passwordData = try? Data(contentsOf: passwordURL),
           let passwordStr = String(data: passwordData, encoding: .utf8) {
            p12Password = passwordStr
        } else {
            p12Password = ""
        }
        isProcessing = true
        currentStage = "Preparing"
        overallProgress = 0.0
        barColor = .blue
        isError = false
        errorDetails = ""
        ProStoreTools.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: p12Password,
            progressUpdate: { message in
                DispatchQueue.main.async {
                    updateProgress(from: message)
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isProcessing = false
                    switch result {
                    case .success(let signedIPAURL):
                        activityURL = signedIPAURL
                        withAnimation {
                            overallProgress = 1.0
                            barColor = .green
                            currentStage = "Done!"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            showActivity = true
                        }
                    case .failure(let error):
                        withAnimation {
                            overallProgress = 1.0
                            barColor = .red
                            currentStage = "Error"
                        }
                        isError = true
                        errorDetails = error.localizedDescription
                    }
                }
            }
        )
    }

    private func updateProgress(from message: String) {
        if message.contains("Preparing") {
            currentStage = "Preparing"
            overallProgress = 0.0
        } else if message.contains("Unzipping") {
            currentStage = "Unzipping"
            if let pct = extractPercentage(from: message) {
                overallProgress = 0.25 + (pct / 100.0) * 0.25
            } else {
                overallProgress = 0.25
            }
        } else if message.contains("Signing") {
            currentStage = "Signing"
            overallProgress = 0.5
        } else if message.contains("Zipping") {
            currentStage = "Zipping"
            if let pct = extractPercentage(from: message) {
                overallProgress = 0.75 + (pct / 100.0) * 0.25
            } else {
                overallProgress = 0.75
            }
        }
    }

    private func extractPercentage(from message: String) -> Double? {
        if let range = message.range(of: "(") {
            let substring = message[range.lowerBound...]
            if let endRange = substring.range(of: "%)") {
                let pctString = substring[..<endRange.lowerBound].dropFirst()
                return Double(pctString)
            }
        }
        return nil
    }
}