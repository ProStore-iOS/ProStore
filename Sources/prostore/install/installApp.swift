// installApp.swift
import Foundation
import IDeviceSwift

/// Installs a signed IPA on the device using InstallationProxy
public func installApp(from ipaURL: URL) async throws {
    print("Installing app from: \(ipaURL.path)")

    // Start heartbeat to keep connection alive during long install
    HeartbeatManager.shared.start()

    // Create view model to receive installation status updates
    let viewModel = InstallerStatusViewModel()

    // Create the installation proxy
    // Note: InstallationProxy(viewModel:) initializer is NOT async in current IDeviceSwift versions
    let installer = InstallationProxy(viewModel: viewModel)

    // Perform the actual installation
    try await installer.install(at: ipaURL)

    print("Installation completed successfully!")
}