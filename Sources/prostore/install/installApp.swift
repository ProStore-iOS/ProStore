// installApp.swift
import Foundation
import IDeviceSwift
import Combine

// MARK: - Error Transformer
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    let errorString = String(describing: error)
    
    // Extract real error message from various formats
    var userMessage = extractUserReadableErrorMessage(from: error)
    
    // If we got a good message, use it
    if let userMessage = userMessage, !userMessage.isEmpty {
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: userMessage]
        )
    }
    
    // Fallback: Generic error 1 handling
    if errorString.contains("error 1.") {
        // Check for specific patterns in the error string
        if errorString.contains("Missing Pairing") {
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Missing pairing file. Please ensure pairing file exists in ProStore folder."]
            )
        }
        
        if errorString.contains("Cannot connect to AFC") || errorString.contains("afc_client_connect") {
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Cannot connect to AFC. Check USB connection, VPN, and accept trust dialog on device."]
            )
        }
        
        if errorString.contains("installation_proxy") {
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Installation service failed. The app may already be installed or device storage full."]
            )
        }
        
        // Generic error 1 message
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: "Installation failed. Make sure: 1) VPN is on, 2) Device is connected via USB, 3) Trust dialog is accepted, 4) Pairing file is in ProStore folder."]
        )
    }
    
    // Try to clean up the generic message
    let originalMessage = nsError.localizedDescription
    let cleanedMessage = cleanGenericErrorMessage(originalMessage)
    
    return NSError(
        domain: nsError.domain,
        code: nsError.code,
        userInfo: [NSLocalizedDescriptionKey: cleanedMessage]
    )
}

// Extract user-readable message from error
private func extractUserReadableErrorMessage(from error: Error) -> String? {
    // Try to get error description from LocalizedError
    if let localizedError = error as? LocalizedError {
        return localizedError.errorDescription
    }
    
    let errorString = String(describing: error)
    
    // Look for specific error patterns in the string representation
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
    
    // Try to extract from NSError userInfo
    let nsError = error as NSError
    if let userInfoMessage = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
       !userInfoMessage.isEmpty,
       userInfoMessage != nsError.localizedDescription {
        return userInfoMessage
    }
    
    return nil
}

// Clean up generic error messages
private func cleanGenericErrorMessage(_ message: String) -> String {
    var cleaned = message
    
    // Remove the generic prefix
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
    
    // Remove trailing period if present
    if cleaned.hasSuffix(".") {
        cleaned = String(cleaned.dropLast())
    }
    
    // If it's just "error 1.", provide more helpful message
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
        throw NSError(
            domain: "InstallApp",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "IPA file not found: \(ipaURL.lastPathComponent)"]
        )
    }
    
    // Check file size
    do {
        let attributes = try fileManager.attributesOfItem(atPath: ipaURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        guard fileSize > 1024 else {
            throw NSError(
                domain: "InstallApp",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "IPA file is too small or invalid"]
            )
        }
    } catch {
        throw NSError(
            domain: "InstallApp",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot read IPA file"]
        )
    }

    print("Installing app from: \(ipaURL.path)")

    return AsyncThrowingStream { continuation in
        Task {
            // Start heartbeat to keep connection alive
            HeartbeatManager.shared.start()

            let viewModel = InstallerStatusViewModel()
            var cancellables = Set<AnyCancellable>()

            // Progress stream
            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .sink { uploadProgress, installProgress in
                    let overallProgress = (uploadProgress + installProgress) / 2.0
                    let status: String

                    if uploadProgress < 1.0 {
                        status = "📤 Uploading..."
                    } else if installProgress < 1.0 {
                        status = "📲 Installing..."
                    } else {
                        status = "🏁 Finalizing..."
                    }

                    continuation.yield((overallProgress, status))
                }
                .store(in: &cancellables)

            // Completion handling
            viewModel.$status
                .sink { installerStatus in
                    switch installerStatus {

                    case .completed(.success):
                        continuation.yield((1.0, "✅ Successfully installed app!"))
                        continuation.finish()
                        cancellables.removeAll()

                    case .completed(.failure(let error)):
                        continuation.finish(
                            throwing: transformInstallError(error)
                        )
                        cancellables.removeAll()

                    case .broken(let error):
                        continuation.finish(
                            throwing: transformInstallError(error)
                        )
                        cancellables.removeAll()

                    default:
                        break
                    }
                }
                .store(in: &cancellables)

            do {
                let installer = await InstallationProxy(viewModel: viewModel)
                try await installer.install(at: ipaURL)

                try await Task.sleep(nanoseconds: 1_000_000_000)
                print("Installation completed successfully!")

            } catch {
                continuation.finish(
                    throwing: transformInstallError(error)
                )
                cancellables.removeAll()
            }
        }
    }
}