import Foundation
import IDeviceSwift

public func installApp(from ipaURL: URL) async throws {
    print("Installing app from \(ipaURL.path)...")

    // Heartbeat
    HeartbeatManager.shared.start()

    // Create installer
    let viewModel = InstallerStatusViewModel()
    let installer = InstallationProxy(viewModel: viewModel)

    // Install IPA
    try await installer.install(at: ipaURL)
}



