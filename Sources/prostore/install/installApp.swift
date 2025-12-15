// installApp.swift
import Foundation
import IDeviceSwift
import Combine

/// Phase-aware install progress reporting.
public enum InstallPhase: String {
    case uploading  = "📤 Uploading"
    case installing = "📲 Installing"
    case finalizing = "⏳ Finalizing"
    case completed  = "✅ Completed"
}

/// Installs a signed IPA on the device using InstallationProxy
/// - Returns: an AsyncThrowingStream that yields `(phase: InstallPhase, progress: Double, status: String)`
///            where `progress` is phase-relative (0.0...1.0).
public func installApp(from ipaURL: URL) async throws -> AsyncThrowingStream<(phase: InstallPhase, progress: Double, status: String), Error> {
    print("Installing app from: \(ipaURL.path)")

    return AsyncThrowingStream { continuation in
        // Keep cancellables outside of the Task so termination handler can access them.
        var cancellables = Set<AnyCancellable>()

        // The actual installation work runs on a Task so we can cancel it if the stream is terminated.
        let installTask = Task {
            // Start heartbeat to keep connection alive during long install
            HeartbeatManager.shared.start()

            // Create view model to receive installation status updates
            let viewModel = InstallerStatusViewModel()

            // Observe progress updates (phase-aware)
            // uploadProgress and installProgress are assumed to be 0.0...1.0 published Doubles.
            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .sink { uploadProgress, installProgress in
                    // Decide which phase is active and yield phase-relative progress
                    if uploadProgress < 1.0 {
                        // Uploading phase
                        let status = "\(InstallPhase.uploading.rawValue)... (\(Int(uploadProgress * 100))%)"
                        DispatchQueue.main.async {
                            continuation.yield((phase: .uploading, progress: uploadProgress, status: status))
                        }
                    } else if installProgress < 1.0 {
                        // Installing phase
                        let status = "\(InstallPhase.installing.rawValue)... (\(Int(installProgress * 100))%)"
                        DispatchQueue.main.async {
                            continuation.yield((phase: .installing, progress: installProgress, status: status))
                        }
                    } else {
                        // Finalizing phase — both reported progress are 1.0, so show finalizing
                        let status = "\(InstallPhase.finalizing.rawValue)..."
                        DispatchQueue.main.async {
                            continuation.yield((phase: .finalizing, progress: 1.0, status: status))
                        }
                    }
                }
                .store(in: &cancellables)

            // Observe installer status for completion/failure
            viewModel.$status
                .sink { installerStatus in
                    switch installerStatus {
                    case .completed(.success):
                        // Report completed (phase-relative = 1.0)
                        let status = "\(InstallPhase.completed.rawValue) Successfully installed app!"
                        DispatchQueue.main.async {
                            continuation.yield((phase: .completed, progress: 1.0, status: status))
                            continuation.finish()
                        }
                        // cleanup
                        cancellables.removeAll()

                    case .completed(.failure(let error)):
                        // Forward the error and finish the stream
                        DispatchQueue.main.async {
                            continuation.finish(throwing: error)
                        }
                        cancellables.removeAll()
                        HeartbeatManager.shared.stop()

                    case .broken(let error):
                        // Broken connection or other fatal error
                        DispatchQueue.main.async {
                            continuation.finish(throwing: error)
                        }
                        cancellables.removeAll()
                        HeartbeatManager.shared.stop()

                    default:
                        break
                    }
                }
                .store(in: &cancellables)

            do {
                // Create the installation proxy
                let installer = await InstallationProxy(viewModel: viewModel)

                // Perform the actual installation
                try await installer.install(at: ipaURL)

                // Allow a short grace period for final signals to arrive
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

                // NOTE: viewModel.$status should drive the final .completed event;
                // if for some reason it didn't, ensure we finish here.
                // (If status already finished the continuation, these calls are no-ops.)
                DispatchQueue.main.async {
                    // If not yet finished, mark completed.
                    continuation.yield((phase: .completed, progress: 1.0, status: "\(InstallPhase.completed.rawValue)"))
                    continuation.finish()
                }

                cancellables.removeAll()
            } catch {
                // On error, forward and cleanup
                DispatchQueue.main.async {
                    continuation.finish(throwing: error)
                }
                cancellables.removeAll()
                HeartbeatManager.shared.stop()
            }
        } // End Task

        // If the consumer cancels/terminates the stream, cancel the install task and cleanup.
        continuation.onTermination = { @Sendable _ in
            installTask.cancel()
            cancellables.removeAll()
            HeartbeatManager.shared.stop()
        }
    }
}


