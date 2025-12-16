// DownloadSignManager.swift
import Foundation
import Combine

class DownloadSignManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: String = ""
    @Published var isProcessing: Bool = false
    @Published var showSuccess: Bool = false

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
        guard let downloadURL = app.downloadURL else {
            self.status = "No download URL available"
            return
        }

        guard let selectedCertFolder = UserDefaults.standard.string(forKey: "selectedCertificateFolder") else {
            self.status = "No certificate selected"
            return
        }

        self.isProcessing = true
        self.progress = 0.0
        self.status = "Starting download..."
        self.showSuccess = false

        DispatchQueue.global(qos: .userInitiated).async {
            self.performDownloadAndSign(downloadURL: downloadURL, appName: app.name, certFolder: selectedCertFolder)
        }
    }

    private func performDownloadAndSign(downloadURL: URL, appName: String, certFolder: String) {
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
                self.status = "Failed to create temp directory: \(error.localizedDescription)"
                self.isProcessing = false
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
                // Step 3: Get certificate files
                guard let (p12URL, provURL, password) = self.getCertificateFiles(for: certFolder) else {
                    DispatchQueue.main.async {
                        self.status = "Failed to get certificate files"
                        self.isProcessing = false
                    }
                    return
                }

                // Step 4: Sign the IPA
                self.signIPA(ipaURL: tempIPAURL, p12URL: p12URL, provURL: provURL, password: password, appName: appName)

            case .failure(let error):
                DispatchQueue.main.async {
                    self.status = "Download failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }

                // Clean up temp file if it exists
                try? FileManager.default.removeItem(at: tempIPAURL)
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
                    self.status = "Cancelled"
                    self.isProcessing = false
                    self.progress = 0.0
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

                        // Clean up original downloaded IPA
                        try? FileManager.default.removeItem(at: ipaURL)

                    case .failure(let error):
                        self.status = "❌ Signing failed: \(error.localizedDescription)"
                        self.isProcessing = false
                        try? FileManager.default.removeItem(at: ipaURL)
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
                    self.status = "❌ Install failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    self.installationStream = nil
                    self.installationTask = nil
                }
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        installationTask?.cancel()
        installationStream = nil
        installationTask = nil

        // Remove observer
        downloadProgressObservation = nil

        DispatchQueue.main.async {
            self.isProcessing = false
            self.status = "Cancelled"
            self.progress = 0.0
        }
    }

    private func getAppFolder() -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appFolder = documents.appendingPathComponent("AppFolder")
        if !fm.fileExists(atPath: appFolder.path) {
            try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        return appFolder
    }
}




