import Foundation
import Combine

public func installAppWithStatus(from ipaURL: URL) async throws {
    let viewModel = InstallerStatusViewModel()
    
    // Connect Combine publishers to your UI
    var cancellables = Set<AnyCancellable>()
    
    viewModel.$uploadProgress
        .sink { [weak self] progress in
            DispatchQueue.main.async {
                self?.status = "📦 Uploading: \(Int(progress * 100))%"
                self?.progress = 0.5 + (progress * 0.25) // optional fine-tune
            }
        }
        .store(in: &cancellables)
    
    viewModel.$installProgress
        .sink { [weak self] progress in
            DispatchQueue.main.async {
                self?.status = "📲 Installing: \(Int(progress * 100))%"
                self?.progress = 0.75 + (progress * 0.25) // optional fine-tune
            }
        }
        .store(in: &cancellables)
    
    viewModel.$status
        .sink { [weak self] status in
            DispatchQueue.main.async {
                self?.status = status
            }
        }
        .store(in: &cancellables)
    
    let installer = InstallationProxy(viewModel: viewModel)
    try await installer.install(at: ipaURL)
}