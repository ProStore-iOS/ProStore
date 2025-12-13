// installApp.swift
import Foundation
import Combine
import IDeviceSwift

// First, let's define the correct InstallerStatus enum if it doesn't exist elsewhere
public enum InstallerStatus {
    case idle
    case uploading(percent: Int)
    case installing(percent: Int)
    case success
    case failure(message: String)
    case message(String)
    
    public var pretty: String {
        switch self {
        case .idle:
            return "Idle"
        case .uploading(let percent):
            return "Uploading... (\(percent)%)"
        case .installing(let percent):
            return "Installing... (\(percent)%)"
        case .success:
            return "✅ Success!"
        case .failure(let message):
            return "❌ \(message)"
        case .message(let text):
            return text
        }
    }
}

// InstallerStatusViewModel with the correct enum
public class InstallerStatusViewModel: ObservableObject {
    @Published public var status: InstallerStatus = .idle
    @Published public var uploadProgress: Double = 0.0
    @Published public var installProgress: Double = 0.0
    // ... other properties as needed
}

public func installAppWithStatusStream(from ipaURL: URL) -> AsyncThrowingStream<InstallerStatus, Error> {
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
