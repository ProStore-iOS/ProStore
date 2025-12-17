// DownloadSignManager.swift - Fixed version with single temp directory
import Foundation
import Combine

@MainActor
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
    
    // Single session temp directory
    private var sessionTempDir: URL?
    private let sessionID = UUID().uuidString

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

        // Create session temp directory
        createSessionTempDirectory()
        
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

    private func createSessionTempDirectory() {
        let fm = FileManager.default
        let sessionTempDir = fm.temporaryDirectory
            .appendingPathComponent("ProStore")
            .appendingPathComponent("session_\(sessionID)")
        
        do {
            if fm.fileExists(atPath: sessionTempDir.path) {
                try fm.removeItem(at: sessionTempDir)
            }
            try fm.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
            self.sessionTempDir = sessionTempDir
        } catch {
            print("Failed to create session temp directory: \(error)")
        }
    }

    private func performDownloadAndSign(downloadURL: URL, appName: String, p12URL: URL, provURL: URL, password: String) {
        guard let sessionTempDir = sessionTempDir else {
            DispatchQueue.main.async {
                self.showError(message: "Failed to create temporary directory")
            }
            return
        }

        let tempIPAURL = sessionTempDir.appendingPathComponent("download.ipa")

        // Step 1: Download the IPA (with progress)
        self.downloadIPA(from: downloadURL, to: tempIPAURL) { [weak self] result in
            guard let self = self else { return }

            // ensure observer cleared
            self.downloadProgressObservation = nil

            switch result {
            case .success:
                // Step 2: Sign the IPA
                self.signIPA(ipaURL: tempIPAURL, p12URL: p12URL, provURL: provURL, 
                           password: password, appName: appName, sessionTempDir: sessionTempDir)

            case .failure(let error):
                DispatchQueue.main.async {
                    self.showError(message: "Download failed: \(error.localizedDescription)")
                }
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
                let err = NSError(domain: "DownloadSignManager", code: -1, 
                                userInfo: [NSLocalizedDescriptionKey: "No temp file URL"])
                completion(.failure(err))
                return
            }

            do {
                // If destination exists, remove it
                let fm = FileManager.default
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.moveItem(at: tempLocalURL, to: destinationURL)

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

    private func signIPA(ipaURL: URL, p12URL: URL, provURL: URL, password: String, appName: String, sessionTempDir: URL) {
        // Update signer to use session temp directory
        let updatedSigner = SigningManager.shared
        updatedSigner.setSessionTempDir(sessionTempDir)
        
        updatedSigner.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: password,
            progressUpdate: { [weak self] status, progress in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let overallProgress = self.downloadPortion + (progress * self.signPortion)
                    self.progress = overallProgress
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

                    case .failure(let error):
                        self.showError(message: "❌ Signing failed: \(error.localizedDescription)")
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
                        self.status = "\(installStatus)"
                    }
                }

                // Installation completed successfully
                await MainActor.run {
                    self.progress = 1.0
                    self.status = "✅ Successfully installed app!"
                    self.showSuccess = true

                    // Hide progress bar after 3 seconds and cleanup
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.isProcessing = false
                        self.showSuccess = false
                        self.progress = 0.0
                        self.status = ""
                        self.installationStream = nil
                        self.installationTask = nil
                        self.cleanupSessionTempDirectory()
                    }
                }

            } catch {
                await MainActor.run {
                    self.showError(message: "❌ Install failed: \(error.localizedDescription)")
                    self.installationStream = nil
                    self.installationTask = nil
                    self.cleanupSessionTempDirectory()
                }
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
                self.cleanupSessionTempDirectory()
            }
        }
    }

    func cancel() {
        cancelTasks()
        cleanupSessionTempDirectory()

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
    // Session temp directory cleanup
    // -----------------------------
    private func cleanupSessionTempDirectory() {
        guard let sessionTempDir = sessionTempDir else { return }
        
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            if fm.fileExists(atPath: sessionTempDir.path) {
                do {
                    try fm.removeItem(at: sessionTempDir)
                    print("Cleaned up session temp directory: \(sessionTempDir.path)")
                } catch {
                    print("Failed to clean up session temp directory: \(error)")
                }
            }
        }
        self.sessionTempDir = nil
    }
}