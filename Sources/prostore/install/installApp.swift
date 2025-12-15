// installApp.swift
import Foundation
import IDeviceSwift
import Combine

/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws -> AsyncThrowingStream<(progress: Double, status: String), Error> {
    print("Installing app from: \(ipaURL.path)")

    return AsyncThrowingStream { continuation in
        Task {
            // Start heartbeat to keep connection alive during long install
            HeartbeatManager.shared.start()

            // Create view model to receive installation status updates
            let viewModel = InstallerStatusViewModel()
            
            // Observe progress updates
            var cancellables = Set<AnyCancellable>()
            
            // Combine progress updates into a single stream
            viewModel.$uploadProgress
                .combineLatest(viewModel.$installProgress)
                .sink { uploadProgress, installProgress in
                    let overallProgress = (uploadProgress + installProgress) / 2.0
                    let currentStage: String
                    
                    if uploadProgress < 1.0 {
                        currentStage = "Uploading..."
                    } else if installProgress < 1.0 {
                        currentStage = "Installing..."
                    } else {
                        currentStage = "Finalizing..."
                    }
                    
                    continuation.yield((progress: overallProgress, status: currentStage))
                }
                .store(in: &cancellables)
            
            // Handle completion
            viewModel.$status
                .sink { installerStatus in
                    switch installerStatus {
                    case .completed(.success):
                        continuation.yield((progress: 1.0, status: "Successfully installed app!"))
                        continuation.finish()
                        cancellables.removeAll()
                        
                    case .completed(.failure(let error)):
                        continuation.finish(throwing: error)
                        cancellables.removeAll()
                        
                    case .broken(let error):
                        continuation.finish(throwing: error)
                        cancellables.removeAll()
                        
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
                
                // Wait a moment for completion
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                print("Installation completed successfully!")
            } catch {
                continuation.finish(throwing: error)
                cancellables.removeAll()
            }
        }
    }
}
