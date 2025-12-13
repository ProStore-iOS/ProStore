// installAppStream.swift
import Foundation
import Combine
import IDeviceSwift

public func installAppWithStatusStream(from ipaURL: URL) -> AsyncThrowingStream<InstallerStatusViewModel.InstallerStatus, Error> {
    AsyncThrowingStream { continuation in
        // create a local view model for the InstallationProxy internals
        let localVM = InstallerStatusViewModel()
        var cancellables = Set<AnyCancellable>()

        // Observe progress and forward into the AsyncStream
        localVM.$uploadProgress
            .sink { progress in
                let pct = Int(progress * 100)
                continuation.yield(.uploading(percent: pct))
            }
            .store(in: &cancellables)

        localVM.$installProgress
            .sink { progress in
                let pct = Int(progress * 100)
                continuation.yield(.installing(percent: pct))
            }
            .store(in: &cancellables)

        // Optionally map other status changes
        localVM.$status
            .sink { status in
                continuation.yield(status)
            }
            .store(in: &cancellables)

        Task {
            do {
                let installer = InstallationProxy(viewModel: localVM)
                try await installer.install(at: ipaURL)
                continuation.yield(.success)
                continuation.finish()
            } catch {
                // forward failure as an enum + error finishing
                continuation.yield(.failure(message: error.localizedDescription))
                continuation.finish(throwing: error)
            }
        }

        // on stream termination, cancel Combine sinks
        continuation.onTermination = { @Sendable _ in
            cancellables.forEach { $0.cancel() }
        }
    }
}