import Foundation
import Combine
import IDeviceSwift

public func installAppWithStatus(from ipaURL: URL, viewModel: InstallerStatusViewModel) async throws {
    var cancellables = Set<AnyCancellable>()
    
    viewModel.$uploadProgress
        .sink { progress in
            DispatchQueue.main.async {
                viewModel.status = "📦 Uploading: \(Int(progress * 100))%"
                viewModel.progress = 0.5 + (progress * 0.25)
            }
        }
        .store(in: &cancellables)
    
    viewModel.$installProgress
        .sink { progress in
            DispatchQueue.main.async {
                viewModel.status = "📲 Installing: \(Int(progress * 100))%"
                viewModel.progress = 0.75 + (progress * 0.25)
            }
        }
        .store(in: &cancellables)
    
    viewModel.$status
        .sink { status in
            DispatchQueue.main.async {
                viewModel.status = status
            }
        }
        .store(in: &cancellables)

    let installer = InstallationProxy(viewModel: viewModel)
    try await installer.install(at: ipaURL)
}