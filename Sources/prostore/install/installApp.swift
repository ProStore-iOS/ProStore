import Foundation
import Combine
import IDeviceSwift

public func installAppWithStatus(from ipaURL: URL, viewModel: InstallerViewModel) async throws {
    var cancellables = Set<AnyCancellable>()

    viewModel.$uploadProgress
        .sink { progress in
            DispatchQueue.main.async {
                let percent = Int(progress * 100)
                viewModel.status = .uploading(percent: percent)
                viewModel.progress = 0.5 + (progress * 0.25)
            }
        }
        .store(in: &cancellables)

    viewModel.$installProgress
        .sink { progress in
            DispatchQueue.main.async {
                let percent = Int(progress * 100)
                viewModel.status = .installing(percent: percent)
                viewModel.progress = 0.75 + (progress * 0.25)
            }
        }
        .store(in: &cancellables)

    // DON'T reassign viewModel.status inside a sink on viewModel.$status —
    // that just creates a loop. If you want to react to status changes elsewhere,
    // observe it and map to UI strings there.

    let installer = InstallationProxy(viewModel: viewModel)
    try await installer.install(at: ipaURL)
}