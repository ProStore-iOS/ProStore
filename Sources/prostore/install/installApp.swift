// installApp.swift
import Foundation
import IDeviceSwift
import Combine

// MARK: - Error Transformer
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    
    // First, extract any meaningful message from the error string
    let errorString = String(describing: error)
    
    // Check for specific IDeviceSwift error patterns
    if let ideviceMessage = extractIDeviceErrorMessage(from: errorString) {
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to install app: \(ideviceMessage)"
            ]
        )
    }
    
    // Check for VPN/connection errors
    if errorString.contains("error 1.") {
        if errorString.lowercased().contains("vpn") || 
           errorString.lowercased().contains("connection") ||
           errorString.lowercased().contains("pairing") ||
           errorString.lowercased().contains("afc") {
            
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to install app! Make sure the LocalDevVPN VPN is turned on and device is connected."
                ]
            )
        }
    }
    
    // Generic pattern extraction for "The operation couldn't be completed. (IDeviceSwiftError error 1.)"
    let pattern = #"The operation .*? be completed\. \((.+? error .+?)\)"#
    let nsDesc = errorString as NSString
    
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: errorString, range: NSRange(location: 0, length: nsDesc.length)),
       match.numberOfRanges > 1 {
        
        let inner = nsDesc.substring(with: match.range(at: 1))
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to install app! (\(inner))"
            ]
        )
    }
    
    // Return original error with cleaned up message
    let originalMessage = nsError.localizedDescription
    let cleanedMessage = cleanErrorMessage(originalMessage)
    
    return NSError(
        domain: nsError.domain,
        code: nsError.code,
        userInfo: [
            NSLocalizedDescriptionKey: cleanedMessage
        ]
    )
}

// Helper to extract IDeviceSwift specific error messages
private func extractIDeviceErrorMessage(from errorString: String) -> String? {
    let lowercasedError = errorString.lowercased()
    
    // Common IDeviceSwift error messages
    let errorPatterns = [
        "missing pairing": "Missing pairing file. Please ensure pairing file exists in ProStore folder.",
        "cannot connect to afc": "Cannot connect to AFC service. Check USB connection and trust dialog.",
        "missing file handle": "File handle error during transfer.",
        "error writing to afc": "Failed to write app to device. Check storage space.",
        "installation_proxy_connect_tcp": "Failed to connect to installation service.",
        "afc_make_directory": "Failed to create staging directory on device.",
        "afc_file_open": "Failed to open file on device.",
        "afc_file_write": "Failed to write file data to device.",
        "afc_file_close": "Failed to close file on device."
    ]
    
    for (pattern, message) in errorPatterns {
        if lowercasedError.contains(pattern.lowercased()) {
            return message
        }
    }
    
    // Try to extract message from IDeviceSwiftError structure
    if let range = errorString.range(of: "_message = \"") {
        let start = errorString.index(range.upperBound, offsetBy: 0)
        if let endRange = errorString[start...].range(of: "\"") {
            let message = String(errorString[start..<endRange.lowerBound])
            if !message.isEmpty {
                return message
            }
        }
    }
    
    // Extract from userInfo if available
    if let userInfoRange = errorString.range(of: "userInfo = ") {
        let userInfoString = String(errorString[userInfoRange.upperBound...])
        if let nsLocalizedRange = userInfoString.range(of: "NSLocalizedDescription = ") {
            let messageStart = userInfoString.index(nsLocalizedRange.upperBound, offsetBy: 0)
            if let messageEnd = userInfoString[messageStart...].firstIndex(of: ";") {
                let message = String(userInfoString[messageStart..<messageEnd])
                if !message.isEmpty && message != "(null)" {
                    return message
                }
            }
        }
    }
    
    return nil
}

// Clean up generic error messages
private func cleanErrorMessage(_ message: String) -> String {
    var cleaned = message
    
    // Remove redundant prefixes
    let prefixes = [
        "The operation couldn't be completed. ",
        "The operation could not be completed. ",
        "IDeviceSwift.IDeviceSwiftError error ",
        "IDeviceSwiftError error "
    ]
    
    for prefix in prefixes {
        if cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
    }
    
    // Clean parentheses
    if cleaned.hasSuffix(".") {
        cleaned = String(cleaned.dropLast())
    }
    
    return cleaned.isEmpty ? "Unknown installation error" : cleaned
}

// MARK: - Install App
/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws
-> AsyncThrowingStream<(progress: Double, status: String), Error> {

    // Pre-flight check: verify IPA exists and is valid
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: ipaURL.path) else {
        throw NSError(
            domain: "InstallApp",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "IPA file not found at: \(ipaURL.path)"]
        )
    }
    
    // Check file size
    do {
        let attributes = try fileManager.attributesOfItem(atPath: ipaURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        guard fileSize > 1024 else { // At least 1KB
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
            userInfo: [NSLocalizedDescriptionKey: "Failed to read IPA file: \(error.localizedDescription)"]
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