// DownloadSignManager.swift
import Foundation
import Combine

final class DownloadSignManager: ObservableObject, @unchecked Sendable {
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    @Published var status: String = ""
    @Published var showSuccess = false

    private var cancellables = Set<AnyCancellable>()
    private var downloadTask: URLSessionDownloadTask?

    func downloadAndSign(app: AltApp) {
        guard let downloadURL = app.downloadURL else {
            status = "No download URL available"
            return
        }

        guard UserDefaults.standard.string(forKey: "selectedCertificateFolder") != nil else {
            status = "No certificate selected"
            return
        }

        isProcessing = true
        progress = 0.0
        status = "Starting download..."
        showSuccess = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performDownloadAndSign(downloadURL: downloadURL, appName: app.name)
        }
    }

    private func performDownloadAndSign(downloadURL: URL, appName: String) {
        let fm = FileManager.default
        let appFolder = getAppFolder()
        let tempDir = appFolder.appendingPathComponent("temp")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.status = "Failed to create temp directory"
                self?.isProcessing = false
            }
            return
        }

        let tempIPAURL = tempDir.appendingPathComponent("\(UUID().uuidString).ipa")

        downloadIPA(from: downloadURL, to: tempIPAURL) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success:
                guard let certFolder = UserDefaults.standard.string(forKey: "selectedCertificateFolder"),
                      let (p12URL, provURL, password) = getCertificateFiles(for: certFolder) else {
                    DispatchQueue.main.async {
                        self.status = "Failed to load certificate"
                        self.isProcessing = false
                    }
                    try? fm.removeItem(at: tempIPAURL)
                    return
                }

                self.signIPA(ipaURL: tempIPAURL, p12URL: p12URL, provURL: provURL, password: password, appName: appName)

            case .failure(let error):
                DispatchQueue.main.async {
                    self.status = "Download failed: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                try? fm.removeItem(at: tempIPAURL)
            }
        }
    }

    private func downloadIPA(from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let tempURL else {
                completion(.failure(NSError(domain: "Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file downloaded"])))
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

        // Progress observation
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let downloadProgress = progress.fractionCompleted * 0.5
            DispatchQueue.main.async {
                self?.progress = downloadProgress
                self?.status = "Downloading... (\(Int(downloadProgress * 200))%)"
            }
        }

        self.downloadTask = task
        task.resume()

        // Clean up observation when task finishes
        task.progress.addObserver(NSObject(), forKeyPath: "fractionCompleted", options: [], context: nil)
        observation.invalidateOnDeallocate(task.progress)
    }

    private func getCertificateFiles(for folderName: String) -> (p12URL: URL, provURL: URL, password: String)? {
        let certsDir = CertificateFileManager.shared.certificatesDirectory
            .appendingPathComponent(folderName)

        let p12URL = certsDir.appendingPathComponent("certificate.p12")
        let provURL = certsDir.appendingPathComponent("profile.mobileprovision")
        let passwordURL = certsDir.appendingPathComponent("password.txt")

        guard FileManager.default.fileExists(atPath: p12URL.path),
              FileManager.default.fileExists(atPath: provURL.path),
              FileManager.default.fileExists(atPath: passwordURL.path),
              let password = try? String(contentsOf: passwordURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        return (p12URL, provURL, password)
    }

    private func signIPA(ipaURL: URL, p12URL: URL, provURL: URL, password: String, appName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status = "Signing \(appName)..."
            self?.progress = 0.5
        }

        signer.sign(
            ipaURL: ipaURL,
            p12URL: p12URL,
            provURL: provURL,
            p12Password: password,
            progressUpdate: { [weak self] statusText, progressFraction in
                DispatchQueue.main.async {
                    let overall = 0.5 + (progressFraction * 0.5)
                    self?.progress = overall
                    self?.status = "\(statusText) (\(Int(overall * 100))%)"
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }

                    switch result => {
                    case .success(let signedIPAURL):
                        self.progress = 1.0
                        self.status = "Signed! Installing..."
                        self.showSuccess = true

                        do {
                            try await installApp(from: signedIPAURL)
                            self.status = "Installed successfully!"
                        } catch {
                            self.status = "Install failed: \(error.localizedDescription)"
                        }

                        // Auto-reset after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.isProcessing = false
                            self.progress = 0.0
                            self.status = ""
                            self.showSuccess = false
                        }

                        // Clean up
                        try? FileManager.default.removeItem(at: ipaURL)
                        try? FileManager.default.removeItem(at: signedIPAURL)

                    case .failure(let error):
                        self.status = "Signing failed: \(error.localizedDescription)"
                        self.isProcessing = false
                        try? FileManager.default.removeItem(at: ipaURL)
                    }
                }
            }
        )
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil

        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = false
            self?.progress = 0.0
            self?.status = "Cancelled"
            self?.showSuccess = false
        }
    }

    private func getAppFolder() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("AppFolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}