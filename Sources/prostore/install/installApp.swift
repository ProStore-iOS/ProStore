//  installApp.swift
import Foundation
import Combine
import IDeviceSwift

// MARK: - Error Transformer (kept + improved)
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    let errorString = String(describing: error)

    // Try to get a readable error first
    if let userMessage = extractUserReadableErrorMessage(from: error),
       !userMessage.isEmpty {
        return NSError(domain: nsError.domain,
                       code: nsError.code,
                       userInfo: [NSLocalizedDescriptionKey: userMessage])
    }

    // Specific patterns for "error 1" cases or common idevice failure messages
    if errorString.contains("error 1") || errorString.contains("error 1.") {
        if errorString.contains("Missing Pairing") {
            return NSError(domain: nsError.domain,
                           code: nsError.code,
                           userInfo: [NSLocalizedDescriptionKey:
                                        "Missing pairing file. Please ensure pairing file exists in the ProStore folder."])
        }
        if errorString.contains("afc_client_connect") || errorString.contains("Cannot connect to AFC") {
            return NSError(domain: nsError.domain,
                           code: nsError.code,
                           userInfo: [NSLocalizedDescriptionKey:
                                        "Cannot connect to AFC. Check USB connection, enable VPN loopback and accept the trust dialog on the device."])
        }
        if errorString.contains("installation_proxy") {
            return NSError(domain: nsError.domain,
                           code: nsError.code,
                           userInfo: [NSLocalizedDescriptionKey:
                                        "Installation service failed. The app may already be installed or device storage is full."])
        }

        return NSError(domain: nsError.domain,
                       code: nsError.code,
                       userInfo: [NSLocalizedDescriptionKey:
                                    "Installation failed. Make sure: 1) VPN is on, 2) Device is connected via USB, 3) Trust dialog is accepted, 4) Pairing file is in ProStore folder."])
    }

    // Clean and fallback
    let cleaned = cleanGenericErrorMessage(nsError.localizedDescription)
    return NSError(domain: nsError.domain,
                   code: nsError.code,
                   userInfo: [NSLocalizedDescriptionKey: cleaned])
}

private func extractUserReadableErrorMessage(from error: Error) -> String? {
    if let localizedError = error as? LocalizedError {
        if let desc = localizedError.errorDescription, !desc.isEmpty { return desc }
    }

    let errString = String(describing: error)

    let patterns: [String: String] = [
        "Missing Pairing": "Missing pairing file. Please check ProStore folder.",
        "Cannot connect to AFC": "Cannot connect to device. Check LocalDevVPN.",
        "AFC Error:": "Device communication failed.",
        "Installation Error:": "App installation failed.",
        "File Error:": "File operation failed.",
        "Connection Failed:": "Connection to device failed."
    ]

    for (pattern, message) in patterns {
        if errString.contains(pattern) {
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
/// Installs a signed IPA on the device using InstallationProxy.
/// NOTE:
/// - If your UI layer already has a shared `InstallationProxy` or `InstallerStatusViewModel`,
///   pass it via the `installer` parameter so we observe the *same* viewModel the installer updates.
/// - If you don't pass one, we attempt to create a fresh `InstallationProxy()` and use its `viewModel`.
public func installApp(
    from ipaURL: URL,
    using installer: InstallationProxy? = nil
) async throws -> AsyncThrowingStream<(progress: Double, status: String), Error> {

    // Pre-flight check: verify IPA exists and is reasonable size
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: ipaURL.path) else {
        throw NSError(domain: "InstallApp",
                      code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "IPA file not found: \(ipaURL.lastPathComponent)"])
    }

    do {
        let attributes = try fileManager.attributesOfItem(atPath: ipaURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        guard fileSize > 1024 else {
            throw NSError(domain: "InstallApp",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "IPA file is too small or invalid"])
        }
    } catch {
        throw NSError(domain: "InstallApp",
                      code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot read IPA file"])
    }

    print("Installing app from: \(ipaURL.path)")

    return AsyncThrowingStream<(progress: Double, status: String), Error> { continuation in
        // We'll run installer work in a Task so stream consumers can cancel the Task by cancelling the stream.
        let installTask = Task {
            HeartbeatManager.shared.start()

            // Get a real installer instance:
            // - If the caller supplied one, use it (recommended).
            // - Otherwise create a new InstallationProxy() and use its viewModel.
            let installerInstance: InstallationProxy
            do {
                if let provided = installer {
                    installerInstance = provided
                } else {
                    // Try to create one. The initializer used here (no-arg) may exist in your codebase.
                    // If your InstallationProxy requires different construction, adjust here.
                    installerInstance = await InstallationProxy()
                }
            } catch {
                // If creating the installer throws for some reason, finish with transformed error
                continuation.finish(throwing: transformInstallError(error))
                return
            }

            // Attempt to obtain the installer's viewModel (the source of truth).
            // If the installer exposes a `viewModel` property, use it. Otherwise, fallback to a fresh one.
            // (Most implementations provide installer.viewModel or let you pass a viewModel to the installer initializer.)
            let viewModel: InstallerStatusViewModel
            if let vm = (installerInstance as AnyObject).value(forKey: "viewModel") as? InstallerStatusViewModel {
                viewModel = vm
            } else {
                // Fallback — create a local viewModel and hope the installer updates it if supported via init(viewModel:).
                viewModel = InstallerStatusViewModel()
            }

            // Keep subscriptions alive for the duration of the stream
            var cancellables = Set<AnyCancellable>()

            // Progress publisher — combine upload + install progress into a single overall progress and status
            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .receive(on: RunLoop.main)
                .sink { uploadProgress, installProgress in
                    let overall = max(0.0, min(1.0, (uploadProgress + installProgress) / 2.0))
                    let statusStr: String
                    if uploadProgress < 1.0 {
                        statusStr = "📤 Uploading..."
                    } else if installProgress < 1.0 {
                        statusStr = "📲 Installing..."
                    } else {
                        statusStr = "🏁 Finalizing..."
                    }
                    continuation.yield((overall, statusStr))
                }
                .store(in: &cancellables)

            // Status updates — listen for completion or broken state
            viewModel.$status
                .receive(on: RunLoop.main)
                .sink { installerStatus in
                    switch installerStatus {
                    case .completed(.success):
                        continuation.yield((1.0, "✅ Successfully installed app!"))
                        continuation.finish()
                        cancellables.removeAll()

                    case .completed(.failure(let error)):
                        continuation.finish(throwing: transformInstallError(error))
                        cancellables.removeAll()

                    case .broken(let error):
                        continuation.finish(throwing: transformInstallError(error))
                        cancellables.removeAll()

                    default:
                        break
                    }
                }
                .store(in: &cancellables)

            // If we fell back to a local viewModel and the InstallationProxy supports init(viewModel:),
            // try to recreate an installer bound to that viewModel so it receives updates.
            // (This is an optional defensive attempt — remove if your API doesn't offer `init(viewModel:)`.)
            if (installer == nil) {
                // If the installer was created without exposing a viewModel (rare), try to re-init with the viewModel.
                // This block is safe to remove if your InstallationProxy doesn't have an init(viewModel:) initializer.
                // Example (uncomment if available in your codebase):
                //
                // let reinstaller = await InstallationProxy(viewModel: viewModel)
                // installerInstance = reinstaller
                //
                // For now, we proceed with the installerInstance we created above.
            }

            // Start the actual installation call
            do {
                try await installerInstance.install(at: ipaURL)
                // small delay for UI to reflect 100%
                try await Task.sleep(nanoseconds: 300_000_000)
                // note: success will be handled by the status publisher above (completed(.success))
                print("Installer.install returned without throwing — waiting for status publisher.")
            } catch {
                // if install throws, map the error neatly and finish the stream
                continuation.finish(throwing: transformInstallError(error))
                cancellables.removeAll()
            }
        } // end Task

        // When the AsyncThrowingStream is terminated (cancelled or finished), cancel the Task too
        continuation.onTermination = { @Sendable termination in
            installTask.cancel()
            // if needed: do any additional cleanup here
        }
    } // end AsyncThrowingStream
}
