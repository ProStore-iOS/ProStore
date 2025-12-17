// SigningManager.swift - Complete fixed version
import Foundation
import ZIPFoundation
import ZsignSwift

// MARK: - Signer Wrapper (for compatibility)
public enum signer {
    public static func sign(
        ipaURL: URL,
        p12URL: URL,
        provURL: URL,
        p12Password: String,
        progressUpdate: @escaping (String, Double) -> Void = { _, _ in },
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        SigningManager.shared.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: p12Password,
            progressUpdate: progressUpdate,
            completion: completion
        )
    }
    
    public static func getExpirationDate(provURL: URL) -> Date? {
        guard let data = try? Data(contentsOf: provURL) else { return nil }
        return getExpirationDate(provData: data)
    }
    
    public static func getExpirationDate(provData: Data) -> Date? {
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)
        
        guard let startRange = provData.range(of: startTag),
              let endRange = provData.range(of: endTag) else {
            return nil
        }
        
        let plistDataSlice = provData[startRange.lowerBound..<endRange.upperBound]
        let plistData = Data(plistDataSlice)
        
        guard let parsed = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = parsed as? [String: Any],
              let expDate = dict["ExpirationDate"] as? Date else {
            return nil
        }
        
        return expDate
    }
}

// MARK: - SigningManager (Main Implementation)
class SigningManager {
    static let shared = SigningManager()
    private var sessionTempDir: URL?
    private var currentSigningTask: Task<Void, Never>?
    
    func setSessionTempDir(_ url: URL) {
        self.sessionTempDir = url
    }
    
    func sign(
        ipaURL: URL,
        p12URL: URL,
        provURL: URL,
        p12Password: String,
        progressUpdate: @escaping (String, Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Cancel any existing task
        currentSigningTask?.cancel()
        
        currentSigningTask = Task {
            do {
                // Ensure we're not cancelled
                try Task.checkCancellation()
                
                progressUpdate("📂 Preparing files...", 0.0)
                
                // Determine temp directory location
                let signingTempDir: URL
                if let sessionDir = self.sessionTempDir {
                    signingTempDir = sessionDir.appendingPathComponent("signing")
                } else {
                    let fm = FileManager.default
                    signingTempDir = fm.temporaryDirectory
                        .appendingPathComponent("ProStoreSigning")
                        .appendingPathComponent(UUID().uuidString)
                }
                
                // Create directory structure
                let inputsDir = signingTempDir.appendingPathComponent("inputs")
                let workDir = signingTempDir.appendingPathComponent("work")
                let outputDir = signingTempDir.appendingPathComponent("output")
                
                let fm = FileManager.default
                try fm.createDirectory(at: inputsDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
                
                // Check for cancellation
                try Task.checkCancellation()
                
                // Copy input files
                progressUpdate("📋 Copying files...", 0.05)
                
                let localIPA = inputsDir.appendingPathComponent("app.ipa")
                let localP12 = inputsDir.appendingPathComponent("cert.p12")
                let localProv = inputsDir.appendingPathComponent("profile.mobileprovision")
                
                // Clean up any existing files
                if fm.fileExists(atPath: localIPA.path) { try? fm.removeItem(at: localIPA) }
                if fm.fileExists(atPath: localP12.path) { try? fm.removeItem(at: localP12) }
                if fm.fileExists(atPath: localProv.path) { try? fm.removeItem(at: localProv) }
                
                // Copy files
                try fm.copyItem(at: ipaURL, to: localIPA)
                try fm.copyItem(at: p12URL, to: localP12)
                try fm.copyItem(at: provURL, to: localProv)
                
                try Task.checkCancellation()
                
                // Extract IPA
                progressUpdate("🔓 Unzipping IPA...", 0.1)
                try await self.extractIPAAsync(ipaURL: localIPA, to: workDir) { progress in
                    let overallProgress = 0.1 + (progress * 0.25)
                    progressUpdate("🔓 Unzipping IPA... (\(Int(progress * 100))%)", overallProgress)
                }
                
                try Task.checkCancellation()
                
                // Find app bundle
                progressUpdate("🔍 Finding app bundle...", 0.35)
                let payloadDir = workDir.appendingPathComponent("Payload")
                let appDir = try self.findAppBundle(in: payloadDir)
                
                try Task.checkCancellation()
                
                // Sign the app
                progressUpdate("✍️ Signing \(appDir.lastPathComponent)...", 0.4)
                let signedAppDir = try await self.signAppAsync(
                    appDir: appDir,
                    p12URL: localP12,
                    provURL: localProv,
                    password: p12Password
                )
                
                try Task.checkCancellation()
                
                // Create new payload with signed app
                progressUpdate("📁 Creating new payload...", 0.8)
                let newPayloadDir = workDir.appendingPathComponent("Payload_Signed")
                if fm.fileExists(atPath: newPayloadDir.path) {
                    try fm.removeItem(at: newPayloadDir)
                }
                try fm.createDirectory(at: newPayloadDir, withIntermediateDirectories: true)
                try fm.copyItem(at: signedAppDir, to: newPayloadDir.appendingPathComponent(signedAppDir.lastPathComponent))
                
                // Zip the signed IPA
                progressUpdate("📦 Zipping signed IPA...", 0.85)
                let signedIPAURL = try await self.createSignedIPAAsync(
                    from: newPayloadDir,
                    outputDir: outputDir
                ) { progress in
                    let overallProgress = 0.85 + (progress * 0.15)
                    progressUpdate("📦 Zipping signed IPA... (\(Int(progress * 100))%)", overallProgress)
                }
                
                // Verify the signed IPA exists
                guard fm.fileExists(atPath: signedIPAURL.path) else {
                    throw NSError(domain: "SigningManager", code: -1, 
                                userInfo: [NSLocalizedDescriptionKey: "Signed IPA not created"])
                }
                
                // If we're not using a session temp dir, we need to move the signed IPA
                // to a location that won't be cleaned up immediately
                if self.sessionTempDir == nil {
                    let finalURL = try self.moveToPersistentLocation(signedIPAURL: signedIPAURL)
                    await MainActor.run {
                        progressUpdate("✅ Signing complete!", 1.0)
                        completion(.success(finalURL))
                    }
                } else {
                    await MainActor.run {
                        progressUpdate("✅ Signing complete!", 1.0)
                        completion(.success(signedIPAURL))
                    }
                }
                
            } catch {
                await MainActor.run {
                    if error is CancellationError {
                        progressUpdate("❌ Signing cancelled", 1.0)
                        completion(.failure(NSError(domain: "SigningManager", code: -999, 
                                                  userInfo: [NSLocalizedDescriptionKey: "Signing cancelled"])))
                    } else {
                        progressUpdate("❌ Signing failed", 1.0)
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    // MARK: - Async Helper Methods
    
    private func extractIPAAsync(
        ipaURL: URL,
        to workDir: URL,
        progressUpdate: @escaping (Double) -> Void
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fm = FileManager.default
                    
                    // Clear work directory if it exists
                    if fm.fileExists(atPath: workDir.path) {
                        try fm.removeItem(at: workDir)
                    }
                    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                    
                    // Extract with progress tracking
                    let progress = Progress()
                    let observation = progress.observe(\Progress.fractionCompleted) { prog, _ in
                        progressUpdate(prog.fractionCompleted)
                    }
                    
                    try fm.unzipItem(at: ipaURL, to: workDir, progress: progress)
                    
                    observation.invalidate()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func signAppAsync(
        appDir: URL,
        p12URL: URL,
        provURL: URL,
        password: String
    ) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use ZsignSwift for signing
                let result = Zsign.sign(
                    appPath: appDir.path,
                    provisionPath: provURL.path,
                    p12Path: p12URL.path,
                    p12Password: password,
                    entitlementsPath: "",
                    removeProvision: false
                ) { success, error in
                    if success {
                        continuation.resume(returning: appDir)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: NSError(domain: "ZsignSwift", code: -1,
                                                            userInfo: [NSLocalizedDescriptionKey: "Unknown signing error"]))
                    }
                }
                
                if !result {
                    continuation.resume(throwing: NSError(domain: "ZsignSwift", code: -1,
                                                        userInfo: [NSLocalizedDescriptionKey: "Signing failed to start"]))
                }
            }
        }
    }
    
    private func createSignedIPAAsync(
        from directory: URL,
        outputDir: URL,
        progressUpdate: @escaping (Double) -> Void
    ) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fm = FileManager.default
                    let signedIPAURL = outputDir.appendingPathComponent("signed.ipa")
                    
                    // Remove existing signed IPA if it exists
                    if fm.fileExists(atPath: signedIPAURL.path) {
                        try fm.removeItem(at: signedIPAURL)
                    }
                    
                    // Zip with progress tracking
                    let progress = Progress()
                    let observation = progress.observe(\Progress.fractionCompleted) { prog, _ in
                        progressUpdate(prog.fractionCompleted)
                    }
                    
                    try fm.zipItem(at: directory, to: signedIPAURL, shouldKeepParent: false, progress: progress)
                    
                    observation.invalidate()
                    
                    // Verify the zip was created
                    guard fm.fileExists(atPath: signedIPAURL.path) else {
                        throw NSError(domain: "SigningManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to create signed IPA"])
                    }
                    
                    let fileSize = try fm.attributesOfItem(atPath: signedIPAURL.path)[.size] as? Int64 ?? 0
                    if fileSize == 0 {
                        throw NSError(domain: "SigningManager", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Signed IPA is empty"])
                    }
                    
                    continuation.resume(returning: signedIPAURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func findAppBundle(in payloadDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: payloadDir.path) else {
            throw NSError(domain: "SigningManager", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Payload directory not found"])
        }
        
        let contents = try fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil, options: [])
        guard let appDir = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "SigningManager", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "No .app bundle found in Payload"])
        }
        
        // Verify it's actually a directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: appDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "SigningManager", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "App bundle is not a directory"])
        }
        
        return appDir
    }
    
    private func moveToPersistentLocation(signedIPAURL: URL) throws -> URL {
        let fm = FileManager.default
        
        // Create a persistent location in the app's documents directory
        let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let signedDir = documentsDir.appendingPathComponent("SignedIPAs")
        
        if !fm.fileExists(atPath: signedDir.path) {
            try fm.createDirectory(at: signedDir, withIntermediateDirectories: true)
        }
        
        // Clean up old signed IPAs (keep last 10)
        let existingFiles = try fm.contentsOfDirectory(at: signedDir, includingPropertiesForKeys: [.creationDateKey], options: [])
        let sortedFiles = existingFiles.sorted { (url1, url2) -> Bool in
            let date1 = try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
            let date2 = try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
            return date1! > date2!
        }
        
        // Remove old files if we have more than 10
        if sortedFiles.count > 10 {
            for file in sortedFiles.dropFirst(10) {
                try? fm.removeItem(at: file)
            }
        }
        
        // Create unique filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let finalFileName = "signed_\(timestamp).ipa"
        let finalURL = signedDir.appendingPathComponent(finalFileName)
        
        // Move the file
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: signedIPAURL, to: finalURL)
        
        return finalURL
    }
    
    func cancel() {
        currentSigningTask?.cancel()
        currentSigningTask = nil
    }
}
