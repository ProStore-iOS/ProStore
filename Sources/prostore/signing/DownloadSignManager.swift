// DownloadSignManager.swift - Updated version (temp-wipe on all outcomes)
import Foundation
import Combine

class DownloadSignManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: String = ""
    @Published var isProcessing: Bool = false
    @Published var showSuccess: Bool = false
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""

    private var downloadTask: URLSessionDownloadTask?
    private var downloadProgressObservation: NSKeyValueObservation?
    private var installationStream: AsyncThrowingStream<(progress: Double, status: String), Error>?
    private var installationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Portion split (tweak if you want different ratios)
    private let downloadPortion: Double = 0.33
    private let signPortion: Double = 0.33
    private let installPortion: Double = 1.0 - (0.33 + 0.33) // ~0.34

    func downloadAndSign(app: AltApp) {
        // Reset error state
        self.showError = false
        self.errorMessage = ""

        // Validate certificate selection
        guard let selectedCertFolder = UserDefaults.standard.string(forKey: "selectedCertificateFolder") else {
            self.showError(message: "No certificate selected. Please select a certificate first.")
            return
        }

        // Validate certificate files exist
        guard let certFiles = getCertificateFiles(for: selectedCertFolder) else {
            self.showError(message: "Certificate files not found or incomplete. Please add a certificate.")
            return
        }

        // Check if pairing file exists (for installation)
        let fm = FileManager.default
        let pairingFile = getAppFolder().appendingPathComponent("pairingFile.plist")
        if !fm.fileExists(atPath: pairingFile.path) {
            self.showError(message: "Pairing file not found. Please follow setup to place pairing file in the 'ProStore' folder.")
            return
        }

        guard let downloadURL = app.downloadURL else {
            self.showError(message: "No download URL available for this app")
            return
        }

        self.isProcessing = true
        self.progress = 0.0
        self.status = "Starting download..."
        self.showSuccess = false

        DispatchQueue.global(qos: .userInitiated).async {
            self.performDownloadAndSign(
                downloadURL: downloadURL,
                appName: app.name,
                p12URL: certFiles.p12URL,
                provURL: certFiles.provURL,
                password: certFiles.password
            )
        }
    }

    private func performDownloadAndSign(downloadURL: URL, appName: String, p12URL: URL, provURL: URL, password: String) {
        // Step 1: Setup directories
        let fm = FileManager.default
        let appFolder = self.getAppFolder()
        let tempDir = appFolder.appendingPathComponent("temp")

        do {
            if !fm.fileExists(atPath: tempDir.path) {
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            }
        } catch {
            DispatchQueue.main.async {
                self.showError(message: "Failed to create temp directory: \(error.localizedDescription)")
                self.cleanupTempDirectory()
            }
            return
        }

        let tempIPAURL = tempDir.appendingPathComponent("\(UUID().uuidString).ipa")

        // Step 2: Download the IPA (with progress)
        self.downloadIPA(from: downloadURL, to: tempIPAURL) { [weak self] result in
            guard let self = self else { return }

            // ensure observer cleared
            self.downloadProgressObservation = nil

            switch result {
            case .success:
                // Step 3: Sign the IPA
                self.signIPA(ipaURL: tempIPAURL, p12URL: p12URL, provURL: provURL, password: password, appName: appName)

            case .failure(let error):
                DispatchQueue.main.async {
                    self.showError(message: "Download failed: \(error.localizedDescription)")
                }

                // Clean up temp folder
                self.cleanupTempDirectory()
            }
        }
    }

    // Download with progress observer and final move to destination
    private func downloadIPA(from url: URL, to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let request = URLRequest(url: url)
        let session = URLSession(configuration: .default)

        DispatchQueue.main.async {
            self.status = "📥 Downloading... (0%)"
            self.progress = 0.0
        }

        let task = session.downloadTask(with: request) { [weak self] tempLocalURL, response, error in
            guard let self = self else { return }

            if let error = error as NSError?, error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                DispatchQueue.main.async {
                    self.showError(message: "Download cancelled")
                }
                completion(.failure(error))
                return
            }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let tempLocalURL = tempLocalURL else {
                let err = NSError(domain: "DownloadSignManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No temp file URL"])
                completion(.failure(err))
                return
            }

            do {
                // If destination exists, remove it
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempLocalURL, to: destinationURL)

                DispatchQueue.main.async {
                    // make sure progress reflects completed download within its portion
                    self.progress = self.downloadPortion
                    self.status = "📥 Downloaded (100%)"
                }

                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        // keep reference for cancel()
        self.downloadTask = task

        // Observe the Progress
        self.downloadProgressObservation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progressObj, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let fraction = progressObj.fractionCompleted // 0.0 .. 1.0
                // Map download fraction to [0 .. downloadPortion]
                let overall = fraction * self.downloadPortion
                self.progress = overall

                let percent = Int(round(fraction * 100))
                self.status = "📥 Downloading... (\(percent)%)"
            }
        }

        task.resume()
    }

    private func getCertificateFiles(for folderName: String) -> (p12URL: URL, provURL: URL, password: String)? {
        let fm = FileManager.default
        let certsDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(folderName)

        let p12URL = certsDir.appendingPathComponent("certificate.p12")
        let provURL = certsDir.appendingPathComponent("profile.mobileprovision")
        let passwordURL = certsDir.appendingPathComponent("password.txt")

        guard fm.fileExists(atPath: p12URL.path),
              fm.fileExists(atPath: provURL.path),
              fm.fileExists(atPath: passwordURL.path) else {
            return nil
        }

        do {
            let password = try String(contentsOf: passwordURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return (p12URL, provURL, password)
        } catch {
            return nil
        }
    }

    private func signIPA(ipaURL: URL, p12URL: URL, provURL: URL, password: String, appName: String) {
        signer.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: password,
            progressUpdate: { [weak self] status, progress in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let overallProgress = self.downloadPortion + (progress * self.signPortion)
                    self.progress = overallProgress
                    let percentOfSign = Int(round(progress * 100))
                    self.status = "\(status)"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let signedIPAURL):
                        // After signing, set progress to end of signing portion
                        self.progress = self.downloadPortion + self.signPortion
                        // Start installation and track progress
                        self.startInstallation(signedIPAURL: signedIPAURL)

                        // Clean up original downloaded IPA (we keep signed IPA for install)
                        try? FileManager.default.removeItem(at: ipaURL)

                    case .failure(let error):
                        self.showError(message: "❌ Signing failed: \(error.localizedDescription)")
                        // Clean up temp folder
                        self.cleanupTempDirectory()
                    }
                }
            }
        )
    }

    private func startInstallation(signedIPAURL: URL) {
        self.installationTask = Task {
            do {
                // Get the installation progress stream
                let stream = try await installApp(from: signedIPAURL)
                self.installationStream = stream

                // Process installation progress updates
                for try await (installProgress, installStatus) in stream {
                    await MainActor.run {
                        // Installation maps to final portion:
                        let overallProgress = self.downloadPortion + self.signPortion + (installProgress * self.installPortion)
                        self.progress = overallProgress

                        let percent = Int(round(overallProgress * 100))
                        if installStatus.contains("Successfully") {
                            self.status = installStatus
                            self.showSuccess = true
                        } else {
                            self.status = "\(installStatus)"
                        }
                    }
                }

                // Installation completed successfully
                await MainActor.run {
                    self.progress = 1.0
                    self.status = "✅ Successfully installed app!"
                    self.showSuccess = true

                    // Clean up temp folder now that install finished successfully
                    self.cleanupTempDirectory()

                    // Hide progress bar after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.isProcessing = false
                        self.showSuccess = false
                        self.progress = 0.0
                        self.status = ""
                        self.installationStream = nil
                        self.installationTask = nil
                    }
                }

            } catch {
                await MainActor.run {
                    self.showError(message: "❌ Install failed: \(error.localizedDescription)")
                    self.installationStream = nil
                    self.installationTask = nil
                }

                // Clean up temp folder after install error
                self.cleanupTempDirectory()
            }
        }
    }

    private func showError(message: String) {
        DispatchQueue.main.async {
            self.progress = 1.0 // Set to 100%
            self.status = message
            self.errorMessage = message
            self.showError = true
            self.isProcessing = true // Keep progress bar visible

            // Hide progress bar after 5 seconds with red state
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.isProcessing = false
                self.showError = false
                self.progress = 0.0
                self.status = ""
                self.errorMessage = ""

                // Clean up any tasks
                self.cancelTasks()

                // Clean temp folder too
                self.cleanupTempDirectory()
            }
        }
    }

    func cancel() {
        cancelTasks()

        // Ensure temp folder cleared on cancel
        cleanupTempDirectory()

        DispatchQueue.main.async {
            self.isProcessing = false
            self.showSuccess = false
            self.showError = false
            self.status = "Cancelled"
            self.progress = 0.0
            self.errorMessage = ""
        }
    }

    private func cancelTasks() {
        downloadTask?.cancel()
        installationTask?.cancel()
        installationStream = nil
        installationTask = nil
        downloadProgressObservation = nil
    }

    private func getAppFolder() -> URL {
        let fm = FileManager.default
        let appFolder = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        if !fm.fileExists(atPath: appFolder.path) {
            try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        return appFolder
    }

    // -----------------------------
    // Temp cleanup helper
    // -----------------------------
    /// Removes the entire `temp` folder (and its contents) asynchronously.
    /// Called on success, failure, or cancel so the temp folder is always wiped.
    private func cleanupTempDirectory() {
        let fm = FileManager.default
        let tempDir = getAppFolder().appendingPathComponent("temp")

        DispatchQueue.global(qos: .utility).async {
            if fm.fileExists(atPath: tempDir.path) {
                do {
                    // Try removing the entire temp dir (fastest)
                    try fm.removeItem(at: tempDir)
                } catch {
                    // Fallback: attempt to remove contents individually
                    if let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: []) {
                        for item in contents {
                            try? fm.removeItem(at: item)
                        }
                    }
                    // Attempt to remove dir again (ignore errors)
                    try? fm.removeItem(at: tempDir)
                }
            }
        }
    }
}
