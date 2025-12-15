// signer.swift
import Foundation
import ZIPFoundation
import ZsignSwift

/// Phase-aware progress reporting for the signing pipeline.
public enum SigningPhase: String {
    case preparing = "Preparing files 📂"
    case unzipping  = "Unzipping IPA 🔓"
    case signing    = "Signing app ✍️"
    case zipping    = "Zipping signed IPA 📦"
    case completed  = "Completed ✅"
}

public enum signer {
    /// New progressUpdate signature: (SigningPhase, Double) -> Void
    /// - `phase` identifies the current phase
    /// - `Double` is the phase-relative progress 0.0...1.0
    public static func sign(
        ipaURL: URL,
        p12URL: URL,
        provURL: URL,
        p12Password: String,
        progressUpdate: @escaping (SigningPhase, Double) -> Void = { _, _ in },
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        SigningManager.sign(
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

fileprivate class SigningManager {

    static func sign(
        ipaURL: URL,
        p12URL: URL,
        provURL: URL,
        p12Password: String,
        progressUpdate: @escaping (SigningPhase, Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Helper to always call progressUpdate on main queue
        func sendProgress(_ phase: SigningPhase, _ fraction: Double) {
            let clamped = min(max(fraction, 0.0), 1.0)
            DispatchQueue.main.async {
                progressUpdate(phase, clamped)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                sendProgress(.preparing, 0.0)
                let (tmpRoot, inputsDir, workDir) = try prepareTemporaryWorkspace()
                defer {
                    cleanupTemporaryFiles(at: tmpRoot)
                }

                let (localIPA, localP12, localProv) = try copyInputFiles(
                    ipaURL: ipaURL,
                    p12URL: p12URL,
                    provURL: provURL,
                    to: inputsDir
                )

                // Preparing finished
                sendProgress(.preparing, 1.0)

                // Unzip phase: report phase-relative progress (0.0..1.0)
                sendProgress(.unzipping, 0.0)
                try extractIPA(ipaURL: localIPA, to: workDir) { phaseProgress in
                    sendProgress(.unzipping, phaseProgress)
                }
                sendProgress(.unzipping, 1.0)

                let payloadDir = workDir.appendingPathComponent("Payload")
                let appDir = try findAppBundle(in: payloadDir)

                // Signing phase: Zsign doesn't provide progress, so indicate start -> finish
                sendProgress(.signing, 0.0)

                let sema = DispatchSemaphore(value: 0)
                var signingError: Error?

                _ = Zsign.sign(
                    appPath: appDir.path,
                    provisionPath: localProv.path,
                    p12Path: localP12.path,
                    p12Password: p12Password,
                    entitlementsPath: "",
                    removeProvision: false
                ) { _, error in
                    signingError = error
                    sema.signal()
                }
                sema.wait()

                if let error = signingError {
                    throw error
                }

                sendProgress(.signing, 1.0)

                // Zipping phase: report phase-relative progress (0.0..1.0)
                sendProgress(.zipping, 0.0)
                let signedIPAURL = try createSignedIPA(
                    from: workDir,
                    originalIPAURL: ipaURL,
                    outputDir: tmpRoot
                ) { phaseProgress in
                    sendProgress(.zipping, phaseProgress)
                }
                sendProgress(.zipping, 1.0)

                // All done
                sendProgress(.completed, 1.0)
                completion(.success(signedIPAURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - workspace helpers
    static func prepareTemporaryWorkspace() throws -> (URL, URL, URL) {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("zsign_ios_\(UUID().uuidString)")
        let inputs = tmpRoot.appendingPathComponent("inputs")
        let work = tmpRoot.appendingPathComponent("work")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        return (tmpRoot, inputs, work)
    }

    static func copyInputFiles(
        ipaURL: URL,
        p12URL: URL,
        provURL: URL,
        to inputsDir: URL
    ) throws -> (URL, URL, URL) {
        let fm = FileManager.default
        let localIPA = inputsDir.appendingPathComponent(ipaURL.lastPathComponent)
        let localP12 = inputsDir.appendingPathComponent(p12URL.lastPathComponent)
        let localProv = inputsDir.appendingPathComponent(provURL.lastPathComponent)
        [localIPA, localP12, localProv].forEach { dest in
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
        }
        try fm.copyItem(at: ipaURL, to: localIPA)
        try fm.copyItem(at: p12URL, to: localP12)
        try fm.copyItem(at: provURL, to: localProv)
        return (localIPA, localP12, localProv)
    }

    static func extractIPA(
        ipaURL: URL,
        to workDir: URL,
        progressUpdate: @escaping (Double) -> Void
    ) throws {
        let fm = FileManager.default
        let progress = Progress()
        let observation = progress.observe(\.fractionCompleted) { prog, _ in
            progressUpdate(prog.fractionCompleted)
        }
        defer {
            observation.invalidate()
        }
        try fm.unzipItem(at: ipaURL, to: workDir, progress: progress)
    }

    static func findAppBundle(in payloadDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: payloadDir.path) else {
            throw NSError(domain: "signer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Payload not found"])
        }
        let contents = try fm.contentsOfDirectory(atPath: payloadDir.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "signer", code: 2, userInfo: [NSLocalizedDescriptionKey: "No .app bundle in Payload"])
        }
        return payloadDir.appendingPathComponent(appName)
    }

    static func createSignedIPA(
        from workDir: URL,
        originalIPAURL: URL,
        outputDir: URL,
        progressUpdate: @escaping (Double) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let finalFileName = "signed_\(UUID().uuidString).ipa"
        let signedIpa = outputDir.appendingPathComponent(finalFileName)
        let progress = Progress()
        let observation = progress.observe(\.fractionCompleted) { prog, _ in
            progressUpdate(prog.fractionCompleted)
        }
        defer {
            observation.invalidate()
        }
        try fm.zipItem(at: workDir, to: signedIpa, shouldKeepParent: false, progress: progress)

        // Copy to AppFolder/temp for permanent storage
        let appFolder = getAppFolder()
        let tempDir = appFolder.appendingPathComponent("temp")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let finalURL = tempDir.appendingPathComponent(finalFileName)
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.copyItem(at: signedIpa, to: finalURL)

        return finalURL
    }

    static func cleanupTemporaryFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func getAppFolder() -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appFolder = documents.appendingPathComponent("AppFolder")
        if !fm.fileExists(atPath: appFolder.path) {
            try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        return appFolder
    }
}
