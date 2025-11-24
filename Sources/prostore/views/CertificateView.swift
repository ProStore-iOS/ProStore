import SwiftUI
import UniformTypeIdentifiers

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

// MARK: - CertificateView (List + Add/Edit launchers)
struct CertificateView: View {
    @State private var customCertificates: [CustomCertificate] = []
    @State private var certExpiries: [String: Date?] = [:]
    @State private var certStatuses: [String: String] = [:]
    @State private var showAddCertificateSheet = false
    @State private var showLoyahdevSheet = false
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
                    showLoyahdevSheet = true
                } label: {
                    Label("Add from Loyahdev", systemImage: "globe")
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
        // Loyahdev sheet
        .sheet(isPresented: $showLoyahdevSheet, onDismiss: {
            reloadCertificatesAndEnsureSelection()
        }) {
            LoyahdevCertificatesView()
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
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            if let expiry = certExpiries[cert.folderName], let validExpiry = expiry {
                expiryDisplay(for: validExpiry)
            } else {
                Text("No expiry date")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            
            if let status = certStatuses[cert.folderName] {
                Text(status)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor(for: status))
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
        guard let expiry = certExpiries[cert.folderName], let validExpiry = expiry,
              let status = certStatuses[cert.folderName] else {
            return Color.clear
        }
        let now = Date()
        let components = Calendar.current.dateComponents([.day], from: now, to: validExpiry)
        let days = components.day ?? 0
        if status != "Signed" || days <= 0 {
            return .red.opacity(0.15)
        } else if days <= 30 {
            return .yellow.opacity(0.15)
        } else {
            return .green.opacity(0.15)
        }
    }
    
    private func statusColor(for status: String) -> Color {
        switch status {
        case "Signed":
            return .green
        case "Revoked", "Mismatch":
            return .red
        case "Unknown":
            return .gray
        default:
            return .secondary
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
        Task {
            await loadExpiries()
        }
    }
 
    private func loadExpiries() async {
        certExpiries = [:]
        certStatuses = [:]
        for cert in customCertificates {
            let folderName = cert.folderName
            let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(folderName)
            let provURL = certDir.appendingPathComponent("profile.mobileprovision")
            let p12URL = certDir.appendingPathComponent("certificate.p12")
            let passwordURL = certDir.appendingPathComponent("password.txt")
            let localExpiry = signer.getExpirationDate(provURL: provURL)
            let password = (try? String(contentsOf: passwordURL, encoding: .utf8)) ?? ""
            let result = await CertRevokeChecker.shared.check(p12URL: p12URL, provisionURL: provURL, password: password)
            switch result {
            case .success(let isSigned, let expires, let match):
                if match {
                    certExpiries[folderName] = expires
                    certStatuses[folderName] = isSigned ? "Signed" : "Revoked"
                } else {
                    certStatuses[folderName] = "Mismatch"
                    certExpiries[folderName] = localExpiry
                }
            case .failure, .networkError:
                certStatuses[folderName] = "Unknown"
                certExpiries[folderName] = localExpiry
            }
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
        Task {
            await loadExpiries()
        }
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
