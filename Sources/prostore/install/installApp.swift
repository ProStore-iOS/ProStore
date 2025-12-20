import Foundation
import IDeviceSwift
import Combine

// MARK: - Error Transformer
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    let errorString = String(describing: error)

    if let userMessage = extractUserReadableErrorMessage(from: error), !userMessage.isEmpty {
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: userMessage])
    }

    if errorString.contains("error 1.") {
        if errorString.contains("Missing Pairing") {
            return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: "Missing pairing file. Please ensure pairing file exists in ProStore folder."])
        }
        if errorString.contains("Cannot connect to AFC") || errorString.contains("afc_client_connect") {
            return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: "Cannot connect to AFC. Check USB connection, VPN, and accept trust dialog on device."])
        }
        if errorString.contains("installation_proxy") {
            return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: "Installation service failed. The app may already be installed or device storage full."])
        }
        return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: "Installation failed. Make sure: 1) VPN is on, 2) Device is connected via USB, 3) Trust dialog is accepted, 4) Pairing file is in ProStore folder."])
    }

    let cleanedMessage = cleanGenericErrorMessage(nsError.localizedDescription)
    return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: cleanedMessage])
}

private func extractUserReadableErrorMessage(from error: Error) -> String? {
    if let localizedError = error as? LocalizedError {
        return localizedError.errorDescription
    }

    let errorString = String(describing: error)
    let patterns = [
        "Missing Pairing": "Missing pairing file. Please check ProStore folder.",
        "Cannot connect to AFC": "Cannot connect to device. Check USB and VPN.",
        "AFC Error:": "Device communication failed.",
        "Installation Error:": "App installation failed.",
        "File Error:": "File operation failed.",
        "Connection Failed:": "Connection to device failed."
    ]

    for (pattern, message) in patterns where errorString.contains(pattern) {
        return message
    }

    let nsError = error as NSError
    if let userInfoMessage = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
       !userInfoMessage.isEmpty,
       userInfoMessage != nsError.localizedDescription {
        return userInfoMessage
    }

    return nil
}

private func cleanGenericErrorMessage(_ message: String) -> String {
    var cleaned = message
    let genericPrefixes = [
        "The operation couldn't be completed. ",
        "The operation could not be completed. ",
        "IDeviceSwift.IDeviceSwiftError ",
        "IDeviceSwiftError "
    ]
    for prefix in genericPrefixes where cleaned.hasPrefix(prefix) {
        cleaned = String(cleaned.dropFirst(prefix.count))
        break
    }
    if cleaned.hasSuffix(".") { cleaned = String(cleaned.dropLast()) }
    if cleaned == "error 1" || cleaned == "error 1." {
        return "Device installation failed. Please check: 1) VPN connection, 2) USB cable, 3) Trust dialog, 4) Pairing file."
    }
    return cleaned.isEmpty ? "Unknown installation error" : cleaned
}

// MARK: - Install App
/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws -> AsyncThrowingStream<(progress: Double, status: String), Error> {

    // Pre-flight IPA check
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: ipaURL.path) else {
        throw NSError(domain: "InstallApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "IPA file not found: \(ipaURL.lastPathComponent)"])
    }

    // Validate file size
    do {
        let attributes = try fileManager.attributesOfItem(atPath: ipaURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        guard fileSize > 1024 else {
            throw NSError(domain: "InstallApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "IPA file is too small or invalid"])
        }
    } catch {
        throw NSError(domain: "InstallApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read IPA file"])
    }

    print("Installing app from: \(ipaURL.path)")

    typealias InstallUpdate = (progress: Double, status: String)
    typealias StreamContinuation = AsyncThrowingStream<InstallUpdate, Error>.Continuation

    return AsyncThrowingStream<InstallUpdate, Error> { continuation in
        var cancellables = Set<AnyCancellable>()
        var installTask: Task<Void, Never>?

        continuation.onTermination = { @Sendable reason in
            print("Install stream terminated: \(reason)")
            cancellables.removeAll()
            installTask?.cancel()
        }

        installTask = Task {
            HeartbeatManager.shared.start()
            let isIdevice = UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
            let viewModel = InstallerStatusViewModel(isIdevice: isIdevice)

            // Status updates
            viewModel.$status
                .sink { newStatus in
                    if viewModel.isCompleted {
                        print("[Installer] detected completion via isCompleted")
                        continuation.yield((1.0, "✅ Successfully installed app!"))
                        continuation.finish()
                        cancellables.removeAll()
                    }
                    if case .broken(let error) = newStatus {
                        continuation.finish(throwing: transformInstallError(error))
                        cancellables.removeAll()
                    }
                }
                .store(in: &cancellables)

            // Progress stream (upload + install)
            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .sink { upload, install in
                    let overall = (upload + install) / 2
                    let statusText: String
                    if upload < 1.0 { statusText = "📤 Uploading..." }
                    else if install < 1.0 { statusText = "📲 Installing..." }
                    else { statusText = "🏁 Finalizing..." }
                    print("[Installer] progress upload:\(upload) install:\(install) overall:\(overall)")
                    continuation.yield((overall, statusText))
                }
                .store(in: &cancellables)

            do {
                let installer = await InstallationProxy(viewModel: viewModel)
                try await installer.install(at: ipaURL)
                try await Task.sleep(nanoseconds: 500_000_000)
                print("Installation call returned — waiting for viewModel to report completion.")
                // Stream finishes when viewModel.isCompleted becomes true or status reports broken/error
            } catch {
                print("[Installer] install threw error ->", error)
                continuation.finish(throwing: transformInstallError(error))
                cancellables.removeAll()
            }
        }
    }
}