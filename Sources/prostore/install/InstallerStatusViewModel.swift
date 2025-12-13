import Foundation
import Combine

public final class InstallerViewModel: ObservableObject {
    public enum InstallerStatus: Equatable {
        case idle
        case uploading(percent: Int)
        case installing(percent: Int)
        case success
        case failure(message: String)
        case message(String)
    }

    // progress sources (0.0 - 1.0)
    @Published public var uploadProgress: Double = 0.0
    @Published public var installProgress: Double = 0.0

    // semantic status and aggregate progress for UI
    @Published public var status: InstallerStatus = .idle
    @Published public var progress: Double = 0.0

    public init() {}
}

// Helpful human-readable mapping
public extension InstallerViewModel.InstallerStatus {
    var pretty: String {
        switch self {
        case .idle: return ""
        case .uploading(let p): return "📦 Uploading: \(p)%"
        case .installing(let p): return "📲 Installing: \(p)%"
        case .success: return "✅ Installation complete!"
        case .failure(let m): return "❌ Install failed: \(m)"
        case .message(let m): return m
        }
    }
}