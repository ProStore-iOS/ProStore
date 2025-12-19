// installApp.swift
import Foundation
import IDeviceSwift
import Combine

// MARK: - Error Transformer
private func transformInstallError(_ error: Error) -> Error {
    let nsError = error as NSError
    let description = nsError.localizedDescription

    // Exact LocalDevVPN VPN error
    if description.contains("IDeviceSwiftError")
     && description.contains("error 1.") {
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey:
                "iDevice failed to install the app! Make sure the LocalDevVPN VPN is turned on!"
            ]
        )
    }

    // Generic: The operation <anything> be completed. (<foo> error <bar>.)
    // Use non-greedy capture and NSRegularExpression for robust extraction
    let pattern = #"The operation .*? be completed\. \((.+? error .+?)\.\)"#

    let nsDesc = description as NSString
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: description, range: NSRange(location: 0, length: nsDesc.length)),
       match.numberOfRanges > 1 {

        let inner = nsDesc.substring(with: match.range(at: 1))

        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey:
                "iDevice failed to install the app! (\(inner).)"
            ]
        )
    }

    // Otherwise: untouched
    return error
}

// MARK: - Install App
/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws
-> AsyncThrowingStream<(progress: Double, status: String), Error> {

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
                        continuation.yield((1.0, "Successfully installed app!"))
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
