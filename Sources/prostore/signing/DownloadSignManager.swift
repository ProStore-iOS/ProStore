// DownloadSignManager.swift
import Foundation
import Combine

class DownloadSignManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: String = ""
    @Published var isProcessing: Bool = false
    @Published var showSuccess: Bool = false
    
    private var downloadTask: URLSessionDownloadTask?
    private var installationStream: AsyncThrowingStream<(progress: Double, status: String), Error>?
    private var installationTask: Task<Void, Never>?
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
    
    private func signIPA(ipaURL: URL, p12URL: URL, provURL: URL, password: String, appName: String) {
        DispatchQueue.main.async {
            self.status = "Starting signing process..."
            self.progress = 0.5
        }
        
        signer.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: password,
            progressUpdate: { [weak self] status, progress in
                DispatchQueue.main.async {
                    // Signing takes first 50% of progress
                    let overallProgress = 0.0 + (progress * 0.5)
                    self?.progress = overallProgress
                    let percent = Int(overallProgress * 100)
                    self?.status = "\(status) (\(percent)%)"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let signedIPAURL):
                        self?.progress = 0.5
                        self?.status = "✅ Signed! Installing app..."
                        
                        // Start installation and track progress
                        self?.startInstallation(signedIPAURL: signedIPAURL)
                        
                        // Clean up original downloaded IPA
                        try? FileManager.default.removeItem(at: ipaURL)
                        
                    case .failure(let error):
                        self?.status = "❌ Signing failed: \(error.localizedDescription)"
                        self?.isProcessing = false
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
                        // Installation takes second 50% of progress (0.5 to 1.0)
                        let overallProgress = 0.5 + (installProgress * 0.5)
                        self.progress = overallProgress
                        
                        let percent = Int(overallProgress * 100)
                        if installStatus.contains("Successfully") {
                            self.status = installStatus
                            self.showSuccess = true
                        } else {
                            self.status = "\(installStatus) (\(percent)%)"
                        }
                    }
                }
                
                // Installation completed successfully
                await MainActor.run {
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
