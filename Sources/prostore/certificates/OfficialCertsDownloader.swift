import SwiftUI
import ZIPFoundation

// MARK: - Release Models
struct Release: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let tagName: String
    let publishedAt: String
    let assets: [Asset]
 
    enum CodingKeys: String, CodingKey {
        case id, name, tagName = "tag_name", publishedAt = "published_at", assets
    }
 
    var publishedDate: Date {
        Date()
    }
}
struct Asset: Codable, Hashable, Equatable {
    let name: String
    let browserDownloadUrl: String
 
    enum CodingKeys: String, CodingKey {
        case name, browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - Tree Models (for Official)
struct TreeResponse: Codable {
    let tree: [TreeItem]
    let truncated: Bool?
}

struct TreeItem: Codable, Identifiable, Hashable, Equatable {
    let path: String
    let type: String
    let url: String
    let sha: String?
    let mode: String?
    
    var id: String { path }
}

// MARK: - Blob Model (for Official)
struct BlobResponse: Codable {
    let content: String?
}

// MARK: - Official Certificates View
struct OfficialCertificatesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var certItems: [TreeItem] = []
    @State private var selectedCert: TreeItem? = nil
    @State private var statusMessage = ""
    @State private var isChecking = false
    @State private var isLoadingCerts = true
    @State private var p12Data: Data? = nil
    @State private var provData: Data? = nil
    @State private var password: String? = nil
    @State private var displayName = ""
    @State private var expiry: Date? = nil
 
    private var isSuccess: Bool {
        statusMessage.contains("Success")
    }
 
    private var statusColor: Color {
        if statusMessage.contains("Fetching") {
            return .yellow
        } else if isSuccess {
            return .green
        } else {
            return .red
        }
    }
 
    var body: some View {
        NavigationStack {
            Form {
                Section("Select Official Certificate") {
                    Picker("Certificate", selection: $selectedCert) {
                        if isLoadingCerts {
                            Text("-- Loading --").tag(nil as TreeItem?)
                        } else {
                            Text("-- Select a certificate --").tag(nil as TreeItem?)
                            ForEach(certItems) { item in
                                Text(item.path).tag(item as TreeItem?)
                            }
                        }
                    }
                }
                Section {
                    Text("Provided by ProStore-iOS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let item = selectedCert {
                    Section("Details") {
                        Text("Name: \(item.path)")
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .foregroundColor(statusColor)
                        }
                        if let exp = expiry {
                            expiryDisplay(for: exp)
                        }
                    }
                }
                Section {
                    Button("Add Certificate") {
                        addCertificate()
                    }
                    .disabled(p12Data == nil || provData == nil || password == nil || isChecking)
                }
            }
            .navigationTitle("Official Certificates")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading:
                Button("×") {
                    dismiss()
                }
            )
            .onAppear {
                fetchTrees()
            }
            .onChange(of: selectedCert) { newValue in
                if newValue != nil && !isChecking {
                    clearCertificateData()
                    checkCertificate()
                } else if newValue == nil {
                    clearCertificateData()
                }
            }
        }
    }
 
    private func clearCertificateData() {
        statusMessage = ""
        expiry = nil
        p12Data = nil
        provData = nil
        password = nil
        displayName = ""
    }
 
    private func expiryDisplay(for expiry: Date) -> some View {
        let now = Date()
        let components = Calendar.current.dateComponents([.day], from: now, to: expiry)
        let days = components.day ?? 0
        let displayDate = expiry.formattedWithOrdinal()
        let expiryText: String
        let expiryColor: Color
        if days > 0 {
            expiryText = "Expires on the \(displayDate)"
            expiryColor = .green
        } else {
            expiryText = "Expired on the \(displayDate)"
            expiryColor = .red
        }
        return Text(expiryText)
            .foregroundColor(expiryColor)
            .font(.caption)
    }
 
    private func fetchTrees() {
        Task {
            let url = URL(string: "https://api.github.com/repos/ProStore-iOS/certificates/git/trees/main")!
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoder = JSONDecoder()
                let response = try decoder.decode(TreeResponse.self, from: data)
                let items = response.tree.filter { $0.type == "tree" }.sorted { $0.path < $1.path }
                await MainActor.run {
                    self.certItems = items
                    self.isLoadingCerts = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to fetch certificates: \(error.localizedDescription)"
                    self.isLoadingCerts = false
                }
            }
        }
    }
 
    private func fetchBlobContent(url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = JSONDecoder()
        let blob = try decoder.decode(BlobResponse.self, from: data)
        guard let content64 = blob.content,
              let decoded = Data(base64Encoded: content64.replacingOccurrences(of: "\n", with: "")) else {
            throw NSError(domain: "Blob", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid blob content"])
        }
        return decoded
    }
 
    private func checkCertificate() {
        guard let item = selectedCert else {
            statusMessage = "Invalid selection"
            return
        }
        isChecking = true
        statusMessage = "Fetching..."
        Task {
            do {
                guard let subURL = URL(string: item.url) else {
                    throw NSError(domain: "URL", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid subdirectory URL"])
                }
                let (subData, _) = try await URLSession.shared.data(from: subURL)
                let decoder = JSONDecoder()
                let subResponse = try decoder.decode(TreeResponse.self, from: subData)
                let subTree = subResponse.tree
                let p12Item = subTree.first { $0.path.hasSuffix(".p12") && $0.type == "blob" }
                let provItem = subTree.first { $0.path.hasSuffix(".mobileprovision") && $0.type == "blob" }
                let pwItem = subTree.first { $0.path == "password.txt" && $0.type == "blob" }
                guard let p12Blob = p12Item, let provBlob = provItem, let pwBlobItem = pwItem else {
                    throw NSError(domain: "Files", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required files"])
                }
                guard let p12URL = URL(string: p12Blob.url),
                      let provURL = URL(string: provBlob.url),
                      let pwURL = URL(string: pwBlobItem.url) else {
                    throw NSError(domain: "URL", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid blob URLs"])
                }
                let p12DataLocal = try await fetchBlobContent(url: p12URL)
                let provDataLocal = try await fetchBlobContent(url: provURL)
                let pwData = try await fetchBlobContent(url: pwURL)
                guard let pwString = String(data: pwData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw NSError(domain: "Password", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid password file"])
                }
                let checkResult = CertificatesManager.check(p12Data: p12DataLocal, password: pwString, mobileProvisionData: provDataLocal)
                switch checkResult {
                case .success(.success):
                    let exp = signer.getExpirationDate(provData: provDataLocal)
                    let dispName = CertificatesManager.shared.getCertificateName(mobileProvisionData: provDataLocal) ?? item.path
                    await MainActor.run {
                        self.p12Data = p12DataLocal
                        self.provData = provDataLocal
                        self.password = pwString
                        self.displayName = dispName
                        self.expiry = exp
                        self.statusMessage = "Success: Ready to add \(dispName)"
                        self.isChecking = false
                    }
                case .success(.incorrectPassword):
                    throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "Incorrect password"])
                case .success(.noMatch):
                    throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "P12 and MobileProvision do not match"])
                case .failure(let error):
                    throw error
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.isChecking = false
                }
            }
        }
    }
 
    private func addCertificate() {
        guard let p12DataLocal = p12Data,
              let provDataLocal = provData,
              let pw = password,
              !displayName.isEmpty else { return }
        isChecking = true
        statusMessage = "Adding..."
        Task {
            do {
                _ = try CertificateFileManager.shared.saveCertificate(p12Data: p12DataLocal, provData: provDataLocal, password: pw, displayName: displayName)
                await MainActor.run {
                    self.statusMessage = "Added successfully"
                    self.isChecking = false
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Error adding: \(error.localizedDescription)"
                    self.isChecking = false
                }
            }
        }
    }
}

