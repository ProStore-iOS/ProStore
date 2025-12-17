// ModelsAndManagers.swift
import Foundation

// MARK: - FileItem
class FileItem: ObservableObject {
    @Published var url: URL?
    var name: String { url?.lastPathComponent ?? "" }
}

// MARK: - CertificateFileManager
class CertificateFileManager {
    static let shared = CertificateFileManager()
    let fileManager = FileManager.default
    let certificatesDirectory: URL
    
    private init() {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        certificatesDirectory = documentsDirectory.appendingPathComponent("certificates")
        createCertificatesDirectoryIfNeeded()
    }
    
    private func createCertificatesDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: certificatesDirectory.path) {
            try? fileManager.createDirectory(at: certificatesDirectory, withIntermediateDirectories: true)
        }
    }
    
    func loadCertificates() -> [CustomCertificate] {
        var resultCerts: [CustomCertificate] = []
        guard let folders = try? fileManager.contentsOfDirectory(at: certificatesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        
        for folder in folders {
            let nameURL = folder.appendingPathComponent("name.txt")
            if fileManager.fileExists(atPath: nameURL.path) {
                if let nameData = try? Data(contentsOf: nameURL),
                   let nameString = String(data: nameData, encoding: .utf8) {
                    resultCerts.append(CustomCertificate(displayName: nameString, folderName: folder.lastPathComponent))
                }
            } else {
                // Fallback display name if missing
                resultCerts.append(CustomCertificate(displayName: folder.lastPathComponent, folderName: folder.lastPathComponent))
            }
        }
        
        return resultCerts
    }
    
    func saveCertificate(p12Data: Data, provData: Data, password: String, displayName: String) throws -> String {
        let baseName = sanitizeFileName(displayName.isEmpty ? "Custom Certificate" : displayName)
        let p12HashNew = CertificatesManager.sha256Hex(p12Data)
        let provHashNew = CertificatesManager.sha256Hex(provData)
        let passwordHashNew = CertificatesManager.sha256Hex(password.data(using: .utf8) ?? Data())
        
        // Check if identical cert already exists
        let existingFolders = try fileManager.contentsOfDirectory(at: certificatesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for folder in existingFolders {
            let p12URL = folder.appendingPathComponent("certificate.p12")
            let provURL = folder.appendingPathComponent("profile.mobileprovision")
            let passwordURL = folder.appendingPathComponent("password.txt")
            if fileManager.fileExists(atPath: p12URL.path) && fileManager.fileExists(atPath: provURL.path) && fileManager.fileExists(atPath: passwordURL.path) {
                do {
                    let existingP12Data = try Data(contentsOf: p12URL)
                    let existingProvData = try Data(contentsOf: provURL)
                    let existingPasswordData = try Data(contentsOf: passwordURL)
                    let existingPassword = String(data: existingPasswordData, encoding: .utf8) ?? ""
                    
                    let p12HashExisting = CertificatesManager.sha256Hex(existingP12Data)
                    let provHashExisting = CertificatesManager.sha256Hex(existingProvData)
                    let passwordHashExisting = CertificatesManager.sha256Hex(existingPassword.data(using: .utf8) ?? Data())
                    
                    if p12HashNew == p12HashExisting && provHashNew == provHashExisting && passwordHashNew == passwordHashExisting {
                        throw NSError(domain: "CertificateFileManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "This certificate already exists"])
                    }
                } catch {
                    // Skip if can't read existing
                    continue
                }
            }
        }
        
        // Create folder
        var finalName = baseName
        var counter = 1
        var folderURL = certificatesDirectory.appendingPathComponent(finalName)
        while fileManager.fileExists(atPath: folderURL.path) {
            counter += 1
            finalName = "\(baseName)-\(counter)"
            folderURL = certificatesDirectory.appendingPathComponent(finalName)
        }
        
        let displayToWrite = uniqueDisplayName(displayName, excludingFolder: finalName)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        try p12Data.write(to: folderURL.appendingPathComponent("certificate.p12"))
        try provData.write(to: folderURL.appendingPathComponent("profile.mobileprovision"))
        try password.data(using: .utf8)?.write(to: folderURL.appendingPathComponent("password.txt"))
        try displayToWrite.data(using: .utf8)?.write(to: folderURL.appendingPathComponent("name.txt"))
        
        return finalName
    }
    
    func updateCertificate(folderName: String, p12Data: Data, provData: Data, password: String, displayName: String) throws {
        let certificateFolder = certificatesDirectory.appendingPathComponent(folderName)
        let p12HashNew = CertificatesManager.sha256Hex(p12Data)
        let provHashNew = CertificatesManager.sha256Hex(provData)
        let passwordHashNew = CertificatesManager.sha256Hex(password.data(using: .utf8) ?? Data())
        
        // Prevent accidental duplicate update matching another cert
        let existingFolders = try fileManager.contentsOfDirectory(at: certificatesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for folder in existingFolders where folder.lastPathComponent != folderName {
            let p12URL = folder.appendingPathComponent("certificate.p12")
            let provURL = folder.appendingPathComponent("profile.mobileprovision")
            let passwordURL = folder.appendingPathComponent("password.txt")
            if fileManager.fileExists(atPath: p12URL.path) && fileManager.fileExists(atPath: provURL.path) && fileManager.fileExists(atPath: passwordURL.path) {
                do {
                    let existingP12Data = try Data(contentsOf: p12URL)
                    let existingProvData = try Data(contentsOf: provURL)
                    let existingPasswordData = try Data(contentsOf: passwordURL)
                    let existingPassword = String(data: existingPasswordData, encoding: .utf8) ?? ""
                    
                    let p12HashExisting = CertificatesManager.sha256Hex(existingP12Data)
                    let provHashExisting = CertificatesManager.sha256Hex(existingProvData)
                    let passwordHashExisting = CertificatesManager.sha256Hex(existingPassword.data(using: .utf8) ?? Data())
                    
                    if p12HashNew == p12HashExisting && provHashNew == provHashExisting && passwordHashNew == passwordHashExisting {
                        throw NSError(domain: "CertificateFileManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "This updated certificate matches another existing one"])
                    }
                } catch {
                    // Skip if can't read existing
                    continue
                }
            }
        }
        
        // Overwrite files
        try p12Data.write(to: certificateFolder.appendingPathComponent("certificate.p12"))
        try provData.write(to: certificateFolder.appendingPathComponent("profile.mobileprovision"))
        try password.data(using: .utf8)?.write(to: certificateFolder.appendingPathComponent("password.txt"))
        let displayToWrite = uniqueDisplayName(displayName, excludingFolder: folderName)
        try displayToWrite.data(using: .utf8)?.write(to: certificateFolder.appendingPathComponent("name.txt"))
    }
    
    func deleteCertificate(folderName: String) throws {
        let certificateFolder = certificatesDirectory.appendingPathComponent(folderName)
        try fileManager.removeItem(at: certificateFolder)
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }

    // Return a unique display name by appending " 1", " 2", ... if needed.
    // `excludingFolder` lets updateCertificate keep the current folder's name out of the conflict check.
    private func uniqueDisplayName(_ desired: String, excludingFolder: String? = nil) -> String {
        let base = desired.isEmpty ? "Custom Certificate" : desired
        var existingNames = Set<String>()
        if let folders = try? fileManager.contentsOfDirectory(at: certificatesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for folder in folders {
                if folder.lastPathComponent == excludingFolder { continue }
                let nameURL = folder.appendingPathComponent("name.txt")
                if let data = try? Data(contentsOf: nameURL), let s = String(data: data, encoding: .utf8) {
                    existingNames.insert(s)
                } else {
                    // fallback to folder name if name.txt missing
                    existingNames.insert(folder.lastPathComponent)
                }
            }
        }

        if !existingNames.contains(base) {
            return base
        }

        var counter = 1
        while existingNames.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }
}

// MARK: - PickerKind Enum
enum PickerKind: Identifiable {
    case ipa, p12, prov
    var id: Int {
        switch self {
        case .ipa: return 0
        case .p12: return 1
        case .prov: return 2
        }
    }
}
enum CertificatePickerKind: Identifiable {
    case p12, prov
    var id: Self { self }
}
