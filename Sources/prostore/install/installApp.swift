import Foundation
import IDeviceSwift
import Combine

// MARK: - Error Transformer (existing helpers kept)
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    let errorString = String(describing: error)

    var userMessage = extractUserReadableErrorMessage(from: error)

    if let userMessage = userMessage, !userMessage.isEmpty {
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

    let originalMessage = nsError.localizedDescription
    let cleanedMessage = cleanGenericErrorMessage(originalMessage)

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

    for (pattern, message) in patterns {
        if errorString.contains(pattern) {
            return message
        }
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

    for prefix in genericPrefixes {
        if cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
            break
        }
    }

    if cleaned.hasSuffix(".") {
        cleaned = String(cleaned.dropLast())
    }

    if cleaned == "error 1" || cleaned == "error 1." {
        return "Device installation failed. Please check: 1) VPN connection, 2) USB cable, 3) Trust dialog, 4) Pairing file."
    }

    return cleaned.isEmpty ? "Unknown installation error" : cleaned
}

// MARK: - Install App
/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws
-> AsyncThrowingStream<(progress: Double, status: String), Error> {

    // Pre-flight check: verify IPA exists
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: ipaURL.path) else {
        throw NSError(domain: "InstallApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "IPA file not found: \(ipaURL.lastPathComponent)"])
    }

    // Check file size
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

    return AsyncThrowingStream { continuation in
        // Keep track of subscriptions & a cancellation token
        var cancellables = Set<AnyCancellable>()
        var installTask: Task<Void, Never>?

        // Ensure cleanup when the stream ends for whatever reason
        continuation.onTermination = { @Sendable _ in
            print("Install stream terminated — cleaning up.")
            cancellables.removeAll()
            HeartbeatManager.shared.stop()
            // cancel the installation task if still running
            installTask?.cancel()
        }

        // Start the async work on a Task so we can await inside
        installTask = Task {
            // Start heartbeat to keep connection alive
            HeartbeatManager.shared.start()

            // initialize view model the same way UI does (important)
            let isIdevice = UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
            let viewModel = InstallerStatusViewModel(isIdevice: isIdevice)

            // Log useful updates to console (debug)
            viewModel.$status.sink { status in
                print("[Installer] status ->", status)
            }.store(in: &cancellables)

            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .sink { uploadProgress, installProgress in
                    let overall = (uploadProgress + installProgress) / 2.0
                    let status: String
                    if uploadProgress < 1.0 {
                        status = "📤 Uploading..."
                    } else if installProgress < 1.0 {
                        status = "📲 Installing..."
                    } else {
                        status = "🏁 Finalizing..."
                    }
                    // debug
                    print("[Installer] progress upload:\(uploadProgress) install:\(installProgress) overall:\(overall)")
                    continuation.yield((overall, status))
                }
                .store(in: &cancellables)

            // Watch for completion via published isCompleted (robust across enum shapes)
            viewModel.$isCompleted
                .sink { completed in
                    if completed {
                        print("[Installer] detected completion via isCompleted=true")
                        continuation.yield((1.0, "✅ Successfully installed app!"))
                        continuation.finish()
                        cancellables.removeAll()
                    }
                }
                .store(in: &cancellables)

            do {
                // Create the installer tied to the view model
                let installer = await InstallationProxy(viewModel: viewModel)

                // If you need same behaviour as UI, pass the suspend flag like the UI does:
                // let suspend = (Bundle.main.bundleIdentifier == someIdentifier) // adapt as needed
                // try await installer.install(at: ipaURL, suspend: suspend)

                // For now, call the simpler signature – change to include 'suspend:' if needed
                try await installer.install(at: ipaURL)

                // tiny pause so progress updates propagate
                try await Task.sleep(nanoseconds: 500_000_000)

                print("Installation call returned without throwing — waiting for viewModel to report completion.")
                // Don't force finish here: wait for the published isCompleted to fire (above)

            } catch {
                print("[Installer] install threw error ->", error)
                continuation.finish(throwing: transformInstallError(error))
                cancellables.removeAll()
            }
        }
    }
}
