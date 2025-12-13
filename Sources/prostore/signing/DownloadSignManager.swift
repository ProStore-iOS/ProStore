// DownloadSignManager.swift
import Foundation
import Combine

class DownloadSignManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: String = ""
    @Published var isProcessing: Bool = false
    @Published var showSuccess: Bool = false
    
    private var downloadTask: URLSessionDownloadTask?
    private var cancellables = Set<AnyCancellable>()
    
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
        
        // Step 2: Download the IPA
        self.downloadIPA(from: downloadURL, to: tempIPAURL) { [weak self] result in
            guard let self = self else { return }
            
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
                self.signAndInstallIPA(ipaURL: tempIPAURL, p12URL: p12URL, provURL: provURL, password: password, appName: appName)
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.status = "Download failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                
                // Clean up temp file if it exists
                try? fm.removeItem(at: tempIPAURL)
            }
        }
    }
    
    private func downloadIPA(from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let tempURL = tempURL else {
                completion(.failure(NSError(domain: "Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "No temp URL returned"])))
                return
            }
            
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tempURL, to: destination)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        
        // Observe download progress
        var observation: NSKeyValueObservation?
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let downloadProgress = progress.fractionCompleted * 0.5 // First 50% for download
            DispatchQueue.main.async {
                self?.progress = downloadProgress
                let percent = Int(downloadProgress * 200) // Convert to 0-100% scale
                self?.status = "Downloading... (\(percent)%)"
            }
        }
        
        self.downloadTask = task
        task.resume()
        
        // Wait for download to complete
        DispatchQueue.global(qos: .userInitiated).async {
            semaphore.wait()
            observation?.invalidate()
        }
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
    
private func signAndInstallIPA(
    ipaURL: URL,
    p12URL: URL,
    provURL: URL,
    password: String,
    appName: String
) {
    DispatchQueue.main.async {
        self.status = "Starting signing process..."
        self.progress = 0.5
        self.isProcessing = true
    }

    signer.sign(
        ipaURL: ipaURL,
        p12URL: p12URL,
        provURL: provURL,
        p12Password: password,
        progressUpdate: { [weak self] status, progress in
            DispatchQueue.main.async {
                let overallProgress = 0.5 + (progress * 0.5)
                self?.progress = overallProgress
                let percent = Int(overallProgress * 100)
                self?.status = "\(status) (\(percent)%)"
            }
        },
        completion: { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let signedIPAURL):
                DispatchQueue.main.async {
                    self.progress = 1.0
                    self.status = "✅ Successfully signed IPA! Installing app now..."
                    self.showSuccess = true
                }

                // Create a view model for installation progress
// Create a view model for installation progress
let installerViewModel = InstallerViewModel()

Task {
    do {
        try await installAppWithStatus(from: signedIPAURL, viewModel: installerViewModel)

        // Observe the viewModel status to update your UI
        installerViewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { status in
                switch status {
                case .idle:
                    break
                case .uploading(let percent), .installing(let percent):
                    self.progress = Double(percent) / 100.0
                    self.status = status.pretty
                case .success:
                    self.status = InstallerViewModel.InstallerStatus.success.pretty
                case .failure(let message):
                    self.status = InstallerViewModel.InstallerStatus.failure(message: message).pretty
                case .message(let text):
                    self.status = text
                }
            }
            .store(in: &self.cancellables)

        // Hide the bar 3 seconds after install is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.isProcessing = false
            self.showSuccess = false
            self.progress = 0.0
            self.status = ""
        }
    } catch {
        DispatchQueue.main.async {
            self.status = "❌ Install failed: \(error.localizedDescription)"
            self.isProcessing = false
        }
    }
}

                // Clean up original downloaded IPA
                try? FileManager.default.removeItem(at: ipaURL)

            case .failure(let error):
                DispatchQueue.main.async {
                    self.status = "❌ Signing failed: \(error.localizedDescription)"
                    self.isProcessing = false
                    try? FileManager.default.removeItem(at: ipaURL)
                }
            }
        }
    )
}
    
    func cancel() {
        downloadTask?.cancel()
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