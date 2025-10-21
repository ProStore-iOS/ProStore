import SwiftUI
import UniformTypeIdentifiers
import ProStoreTools
import ZIPFoundation
// Centralized types to avoid conflicts
struct CertificateFileItem {
    var name: String = ""
    var url: URL?
}
struct CustomCertificate: Identifiable {
    let id = UUID()
    let displayName: String
    let folderName: String
}
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
// MARK: - Official Certificates View
struct OfficialCertificatesView: View {
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
                Section("Select Official Certificate") {
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
            .navigationTitle("Official Certificates")
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
// MARK: - CertificateView (List + Add/Edit launchers)
struct CertificateView: View {
    @State private var customCertificates: [CustomCertificate] = []
    @State private var certExpiries: [String: Date?] = [:]
    @State private var showAddCertificateSheet = false
    @State private var showOfficialSheet = false
    @State private var editingCertificate: CustomCertificate? = nil // Used only for edit sheet (.sheet(item:))
    @State private var selectedCert: String? = nil
    @State private var showingDeleteAlert = false
    @State private var certToDelete: CustomCertificate?
    @State private var newlyAddedFolder: String? = nil
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(customCertificates) { cert in
                    certificateItem(for: cert)
                }
            }
            .padding()
        }
        .background(Color(.systemGray6))
        .navigationBarItems(trailing:
            Menu {
                Button {
                    showAddCertificateSheet = true
                } label: {
                    Label("Add from Files", systemImage: "folder.badge.plus")
                }
                Button {
                    showOfficialSheet = true
                } label: {
                    Label("Add from Official", systemImage: "globe")
                }
            } label: {
                Image(systemName: "plus")
            }
        )
        // ADD sheet (new certificate only)
        .sheet(isPresented: $showAddCertificateSheet, onDismiss: {
            reloadCertificatesAndEnsureSelection()
            if let newFolder = newlyAddedFolder {
                selectedCert = newFolder
                UserDefaults.standard.set(selectedCert, forKey: "selectedCertificateFolder")
                newlyAddedFolder = nil
            }
        }) {
            AddCertificateView(onSave: { newlyAddedFolder = $0 })
                .presentationDetents([.large])
        }
        // Official sheet
        .sheet(isPresented: $showOfficialSheet, onDismiss: {
            reloadCertificatesAndEnsureSelection()
        }) {
            OfficialCertificatesView()
                .presentationDetents([.large])
        }
        // EDIT sheet (identifiable)
        .sheet(item: $editingCertificate, onDismiss: {
            reloadCertificatesAndEnsureSelection()
        }) { editing in
            AddCertificateView(editingCertificate: editing)
                .presentationDetents([.large])
        }
        .alert("Delete Certificate?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let cert = certToDelete {
                    deleteCertificate(cert)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure? This can't be undone.")
        }
        .onAppear {
            reloadCertificatesAndEnsureSelection()
        }
    }
   
    private func certificateItem(for cert: CustomCertificate) -> some View {
        ZStack(alignment: .top) {
            certificateContent(for: cert)
                .onTapGesture {
                    // Only allow deselection if there are other certificates available
                    if selectedCert == cert.folderName && customCertificates.count > 1 {
                        if let nextCert = customCertificates.first(where: { $0.folderName != cert.folderName }) {
                            selectedCert = nextCert.folderName
                            UserDefaults.standard.set(selectedCert, forKey: "selectedCertificateFolder")
                        }
                    } else {
                        selectedCert = cert.folderName
                        UserDefaults.standard.set(selectedCert, forKey: "selectedCertificateFolder")
                    }
                }
            certificateButtons(for: cert)
        }
    }
   
    private func certificateContent(for cert: CustomCertificate) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Text(cert.displayName)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            if let expiry = certExpiries[cert.folderName], let validExpiry = expiry {
                expiryDisplay(for: validExpiry)
            } else {
                Text("No expiry date")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(certificateBackground(for: cert))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(selectedCert == cert.folderName ? Color.blue : Color.clear, lineWidth: 3)
        )
    }
   
    private func expiryDisplay(for expiry: Date) -> some View {
        let now = Date()
        let components = Calendar.current.dateComponents([.day], from: now, to: expiry)
        let days = components.day ?? 0
        let displayDate = expiry.formattedWithOrdinal()
        let expiryText: String
        if days > 0 {
            expiryText = "Expires in \(days) days on \(displayDate)"
        } else {
            let pastDays = abs(days)
            expiryText = "Expired \(pastDays) days ago on \(displayDate)"
        }
        return Text(expiryText)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.primary)
    }
   
    private func certificateBackground(for cert: CustomCertificate) -> Color {
        guard let expiry = certExpiries[cert.folderName], expiry != nil else {
            return Color.clear
        }
        let now = Date()
        let components = Calendar.current.dateComponents([.day], from: now, to: expiry!)
        let days = components.day ?? 0
        switch days {
        case ..<0, 0:
            return .red.opacity(0.15)
        case 1...30:
            return .yellow.opacity(0.15)
        default:
            return .green.opacity(0.15)
        }
    }
   
    private func certificateButtons(for cert: CustomCertificate) -> some View {
        HStack {
            Button(action: {
                // EDIT: trigger identifiable sheet
                editingCertificate = cert
            }) {
                Image(systemName: "pencil")
                    .foregroundColor(.blue)
                    .font(.caption)
                    .padding(8)
                    .background(Color(.systemGray6).opacity(0.8))
                    .clipShape(Circle())
            }
        
            Spacer()
        
            Button(action: {
                if customCertificates.count > 1 {
                    certToDelete = cert
                    showingDeleteAlert = true
                }
            }) {
                Image(systemName: "trash")
                    .foregroundColor(customCertificates.count > 1 ? .red : .gray)
                    .font(.caption)
                    .padding(8)
                    .background(Color(.systemGray6).opacity(0.8))
                    .clipShape(Circle())
            }
            .disabled(customCertificates.count <= 1)
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
    }
    private func reloadCertificatesAndEnsureSelection() {
        customCertificates = CertificateFileManager.shared.loadCertificates()
        selectedCert = UserDefaults.standard.string(forKey: "selectedCertificateFolder")
        ensureSelection()
        loadExpiries()
    }
   
    private func loadExpiries() {
        for cert in customCertificates {
            let folderName = cert.folderName
            let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(folderName)
            let provURL = certDir.appendingPathComponent("profile.mobileprovision")
            let expiry = ProStoreTools.getExpirationDate(provURL: provURL)
            certExpiries[folderName] = expiry
        }
    }
    private func ensureSelection() {
        if selectedCert == nil || !customCertificates.contains(where: { $0.folderName == selectedCert }) {
            if let firstCert = customCertificates.first {
                selectedCert = firstCert.folderName
                UserDefaults.standard.set(selectedCert, forKey: "selectedCertificateFolder")
            }
        }
    }
    private func deleteCertificate(_ cert: CustomCertificate) {
        try? CertificateFileManager.shared.deleteCertificate(folderName: cert.folderName)
        customCertificates = CertificateFileManager.shared.loadCertificates()
    
        if selectedCert == cert.folderName {
            if let newSelection = customCertificates.first {
                selectedCert = newSelection.folderName
                UserDefaults.standard.set(selectedCert, forKey: "selectedCertificateFolder")
            } else {
                selectedCert = nil
                UserDefaults.standard.removeObject(forKey: "selectedCertificateFolder")
            }
        }
        ensureSelection()
        loadExpiries()
    }
}
// MARK: - Add / Edit View
struct AddCertificateView: View {
    @Environment(\.dismiss) private var dismiss
    let editingCertificate: CustomCertificate?
    let onSave: ((String) -> Void)?
    @State private var p12File: CertificateFileItem?
    @State private var provFile: CertificateFileItem?
    @State private var password = ""
    @State private var activeSheet: CertificatePickerKind?
    @State private var isChecking = false
    @State private var errorMessage = ""
    @State private var displayName: String = ""
    @State private var hasLoadedForEdit = false
    init(editingCertificate: CustomCertificate? = nil, onSave: ((String) -> Void)? = nil) {
        self.editingCertificate = editingCertificate
        self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Files")) {
                    Button(action: { activeSheet = .p12 }) {
                        HStack {
                            Image(systemName: "lock.doc.fill")
                                .foregroundColor(.blue)
                            Text("Import Certificate (.p12) File")
                            Spacer()
                            if let p12File = p12File {
                                Text(p12File.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(isChecking)
                
                    Button(action: { activeSheet = .prov }) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.blue)
                            Text("Import Provisioning (.mobileprovision) File")
                            Spacer()
                            if let provFile = provFile {
                                Text(provFile.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(isChecking)
                }
            
                Section(header: Text("Display Name")) {
                    TextField("Optional Display Name", text: $displayName)
                        .disabled(isChecking)
                }
            
                Section(header: Text("Password")) {
                    SecureField("Enter Password", text: $password)
                        .disabled(isChecking)
                    Text("Enter the password for the certificate. Leave it blank if there is no password needed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
            }
            .navigationTitle(editingCertificate != nil ? "Edit Certificate" : "New Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading:
                Button("×") {
                    dismiss()
                }
                .disabled(isChecking)
            , trailing:
                Group {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("Save") {
                            saveCertificate()
                        }
                        .disabled(p12File == nil || provFile == nil)
                    }
                }
            )
            .sheet(item: $activeSheet) { sheetType in
                CertificateDocumentPicker(kind: sheetType) { url in
                    if sheetType == .p12 {
                        p12File = CertificateFileItem(name: url.lastPathComponent, url: url)
                    } else {
                        provFile = CertificateFileItem(name: url.lastPathComponent, url: url)
                    }
                    errorMessage = ""
                }
            }
            .onChange(of: password) { _ in
                errorMessage = ""
            }
            .onAppear {
                if let cert = editingCertificate, !hasLoadedForEdit {
                    loadForEdit(cert: cert)
                    hasLoadedForEdit = true
                }
            }
        }
    }
    private func loadForEdit(cert: CustomCertificate) {
        let certFolder = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(cert.folderName)
        let p12URL = certFolder.appendingPathComponent("certificate.p12")
        let provURL = certFolder.appendingPathComponent("profile.mobileprovision")
        let passwordURL = certFolder.appendingPathComponent("password.txt")
        let nameURL = certFolder.appendingPathComponent("name.txt")
    
        p12File = CertificateFileItem(name: "certificate.p12", url: p12URL)
        provFile = CertificateFileItem(name: "profile.mobileprovision", url: provURL)
    
        if let pwData = try? Data(contentsOf: passwordURL), let pw = String(data: pwData, encoding: .utf8) {
            password = pw
        }
        if let nameData = try? Data(contentsOf: nameURL), let nameStr = String(data: nameData, encoding: .utf8) {
            displayName = nameStr
        }
    }
   
    private func saveCertificate() {
        guard let p12URL = p12File?.url, let provURL = provFile?.url else { return }
    
        isChecking = true
        errorMessage = ""
    
        let workItem: DispatchWorkItem = DispatchWorkItem {
            do {
                var p12Data: Data
                var provData: Data
                var localDisplayName = self.displayName
                if self.editingCertificate != nil {
                    p12Data = try Data(contentsOf: p12URL)
                    provData = try Data(contentsOf: provURL)
                } else {
                    let p12Scoped = p12URL.startAccessingSecurityScopedResource()
                    let provScoped = provURL.startAccessingSecurityScopedResource()
                    defer {
                        if p12Scoped { p12URL.stopAccessingSecurityScopedResource() }
                        if provScoped { provURL.stopAccessingSecurityScopedResource() }
                    }
                    p12Data = try Data(contentsOf: p12URL)
                    provData = try Data(contentsOf: provURL)
                }
            
                let checkResult = CertificatesManager.check(p12Data: p12Data, password: self.password, mobileProvisionData: provData)
                var dispatchError: String?
            
                switch checkResult {
                case .success(.success):
                    if localDisplayName.isEmpty {
                        localDisplayName = CertificatesManager.getCertificateName(mobileProvisionData: provData) ?? "Custom Certificate"
                    }
                
                    if let folder = self.editingCertificate?.folderName {
                        try CertificateFileManager.shared.updateCertificate(folderName: folder, p12Data: p12Data, provData: provData, password: self.password, displayName: localDisplayName)
                    } else {
                        let newFolder = try CertificateFileManager.shared.saveCertificate(p12Data: p12Data, provData: provData, password: self.password, displayName: localDisplayName)
                        self.onSave?(newFolder)
                    }
                case .success(.incorrectPassword):
                    dispatchError = "Incorrect Password"
                case .success(.noMatch):
                    dispatchError = "P12 and MobileProvision do not match"
                case .failure(let error):
                    dispatchError = "Error: \(error.localizedDescription)"
                }
            
                DispatchQueue.main.async {
                    self.isChecking = false
                    if let err = dispatchError {
                        self.errorMessage = err
                    } else {
                        self.dismiss()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isChecking = false
                    self.errorMessage = "Failed to read files or save: \(error.localizedDescription)"
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}