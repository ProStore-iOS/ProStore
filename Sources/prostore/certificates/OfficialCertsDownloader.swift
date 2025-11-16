import SwiftUI
import ZIPFoundation

// MARK: - Release Models (for Loyahdev)
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

struct TreeItem: Codable, Identifiable {
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

// MARK: - Date Extension for Formatting
extension Date {
    func formattedWithOrdinal() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: self)
        let day = Calendar.current.component(.day, from: self)
        let ordinal = ordinalSuffix(for: day)
        let year = Calendar.current.component(.year, from: self)
        return "\(ordinal) of \(month) \(year)"
    }
 
    private func ordinalSuffix(for number: Int) -> String {
        let suffix: String
        let ones = number % 10
        let tens = (number / 10) % 10
        if tens == 1 {
            suffix = "th"
        } else if ones == 1 {
            suffix = "st"
        } else if ones == 2 {
            suffix = "nd"
        } else if ones == 3 {
            suffix = "rd"
        } else {
            suffix = "th"
        }
        return "\(number)\(suffix)"
    }
}

// MARK: - Loyahdev Certificates View
struct LoyahdevCertificatesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var releases: [Release] = []
    @State private var selectedRelease: Release? = nil
    @State private var statusMessage = ""
    @State private var isChecking = false
    @State private var isLoadingReleases = true
    @State private var p12Data: Data? = nil
    @State private var provData: Data? = nil
    @State private var password: String? = nil
    @State private var displayName = ""
    @State private var expiry: Date? = nil
 
    private var isSuccess: Bool {
        statusMessage.contains("Success")
    }
 
    private var statusColor: Color {
        if statusMessage.contains("Downloading") {
            return .yellow
        } else if isSuccess {
            return .green
        } else {
            return .red
        }
    }
 
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
 
    var body: some View {
        NavigationStack {
            Form {
                Section("Select Loyahdev Certificate") {
                    Picker("Certificate", selection: $selectedRelease) {
                        if isLoadingReleases {
                            Text("-- Loading --").tag(nil as Release?)
                        } else {
                            Text("-- Select a certificate --").tag(nil as Release?)
                            ForEach(releases) { release in
                                Text(cleanName(release.name)).tag(release as Release?)
                            }
                        }
                    }
                }
                Section {
                    Text("Provided by loyahdev")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let release = selectedRelease {
                    Section("Details") {
                        Text("Tag: \(release.tagName)")
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .foregroundColor(statusColor)
                        }
                        Text("Published: \(dateFormatter.string(from: isoDate(string: release.publishedAt)))")
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
            .navigationTitle("Loyahdev Certificates")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading:
                Button("×") {
                    dismiss()
                }
            )
            .onAppear {
                fetchReleases()
            }
            .onChange(of: selectedRelease) { newValue in
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
 
    private func isoDate(string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string) ?? Date()
    }
 
    private func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\", with: "")
    }
 
    private func getPAT() async -> String? {
        guard let url = URL(string: "https://certapi.loyah.dev/pac") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
 
    private func fetchReleases() {
        Task {
            let pat = await getPAT()
            let url = URL(string: "https://api.github.com/repos/loyahdev/certificates/releases")!
            var request = URLRequest(url: url)
            if let pat = pat {
                request.setValue("token \(pat)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                var decodeData = data
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200, pat != nil {
                    let fallbackRequest = URLRequest(url: url)
                    let (fallbackData, _) = try await URLSession.shared.data(for: fallbackRequest)
                    decodeData = fallbackData
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .deferredToDate
                let decoded = try decoder.decode([Release].self, from: decodeData)
                await MainActor.run {
                    self.releases = decoded.sorted { isoDate(string: $0.publishedAt) > isoDate(string: $1.publishedAt) }
                    self.isLoadingReleases = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to fetch releases: \(error.localizedDescription)"
                    self.isLoadingReleases = false
                }
            }
        }
    }
 
    private func findCertificateFiles(in directory: URL) throws -> (p12Urls: [URL], provUrls: [URL]) {
        var p12Urls: [URL] = []
        var provUrls: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                if !path.contains("__MACOSX") {
                    if path.hasSuffix(".p12") {
                        p12Urls.append(fileURL)
                    } else if path.hasSuffix(".mobileprovision") {
                        provUrls.append(fileURL)
                    }
                }
            }
        }
        return (p12Urls, provUrls)
    }
 
    private func checkCertificate() {
        guard let release = selectedRelease,
              let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let downloadUrl = URL(string: asset.browserDownloadUrl) else {
            statusMessage = "Invalid release"
            return
        }
        isChecking = true
        statusMessage = "Downloading..."
        Task {
            let pat = await getPAT()
            var downloadRequest = URLRequest(url: downloadUrl)
            if let pat = pat {
                downloadRequest.setValue("token \(pat)", forHTTPHeaderField: "Authorization")
            }
            do {
                var tempData = Data()
                var response = URLResponse()
                (tempData, response) = try await URLSession.shared.data(for: downloadRequest)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200, pat != nil {
                    let fallbackRequest = URLRequest(url: downloadUrl)
                    (tempData, _) = try await URLSession.shared.data(for: fallbackRequest)
                }
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
                defer {
                    try? FileManager.default.removeItem(at: tempDir)
                }
                let zipPath = tempDir.appendingPathComponent("temp.zip")
                try tempData.write(to: zipPath)
                let extractDir = tempDir.appendingPathComponent("extracted")
                try FileManager.default.unzipItem(at: zipPath, to: extractDir, progress: nil)
                // Find files
                let (p12Urls, provUrls) = try findCertificateFiles(in: extractDir)
                guard p12Urls.count == 1, provUrls.count == 1 else {
                    throw NSError(domain: "Extraction", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to extract certificate"])
                }
                let p12Url = p12Urls[0]
                let provUrl = provUrls[0]
                let p12DataLocal = try Data(contentsOf: p12Url)
                let provDataLocal = try Data(contentsOf: provUrl)
                var successPw: String?
                for pwCandidate in ["Hydrogen", "Sideloadingdotorg", "nocturnacerts"] {
                    switch CertificatesManager.check(p12Data: p12DataLocal, password: pwCandidate, mobileProvisionData: provDataLocal) {
                    case .success(.success):
                        successPw = pwCandidate
                        break
                    default:
                        break
                    }
                }
                guard let pw = successPw else {
                    throw NSError(domain: "Password", code: 1, userInfo: [NSLocalizedDescriptionKey: "Password check failed"])
                }
                let exp = ProStoreTools.getExpirationDate(provData: provDataLocal)
                let dispName = CertificatesManager.getCertificateName(mobileProvisionData: provDataLocal) ?? cleanName(release.name)
                await MainActor.run {
                    self.p12Data = p12DataLocal
                    self.provData = provDataLocal
                    self.password = pw
                    self.displayName = dispName
                    self.expiry = exp
                    self.statusMessage = "Success: Ready to add \(dispName)"
                    self.isChecking = false
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
                let subUrl = item.url
                let (subData, _) = try await URLSession.shared.data(from: subUrl)
                let decoder = JSONDecoder()
                let subResponse = try decoder.decode(TreeResponse.self, from: subData)
                let subTree = subResponse.tree
                let p12Item = subTree.first { $0.path.hasSuffix(".p12") && $0.type == "blob" }
                let provItem = subTree.first { $0.path.hasSuffix(".mobileprovision") && $0.type == "blob" }
                let pwItem = subTree.first { $0.path == "password.txt" && $0.type == "blob" }
                guard let p12Blob = p12Item, let provBlob = provItem, let pwBlobItem = pwItem else {
                    throw NSError(domain: "Files", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required files"])
                }
                let p12DataLocal = try await fetchBlobContent(url: p12Blob.url)
                let provDataLocal = try await fetchBlobContent(url: provBlob.url)
                let pwData = try await fetchBlobContent(url: pwBlobItem.url)
                guard let pwString = String(data: pwData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw NSError(domain: "Password", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid password file"])
                }
                let checkResult = CertificatesManager.check(p12Data: p12DataLocal, password: pwString, mobileProvisionData: provDataLocal)
                switch checkResult {
                case .success(.success):
                    let exp = ProStoreTools.getExpirationDate(provData: provDataLocal)
                    let dispName = CertificatesManager.getCertificateName(mobileProvisionData: provDataLocal) ?? item.path
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