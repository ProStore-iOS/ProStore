import SwiftUI

// MARK: - Models (AltStore-ish)
struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let apps: [AltApp]?
}

struct AltApp: Decodable, Identifiable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let iconURL: URL?
    let localizedDescription: String?
    let versions: [AppVersion]?
    
    var latestDownloadURL: URL? {
        versions?.first?.downloadURL
    }
}

struct AppVersion: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let downloadURL: URL?
    let size: Int?
    let minOSVersion: String?
    let maxOSVersion: String?
}

// MARK: - ViewModel
@MainActor
final class RepoViewModel: ObservableObject {
    @Published var apps: [AltApp] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    private let sourceURL: URL
    
    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        Task { await load() }
    }
    
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            var request = URLRequest(url: sourceURL)
            request.setValue("ProStore/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "RepoFetcher", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            
            let decoder = JSONDecoder()
            // try common shapes
            if let source = try? decoder.decode(AltSource.self, from: data), let apps = source.apps {
                self.apps = apps
                return
            }
            if let appsArray = try? decoder.decode([AltApp].self, from: data) {
                self.apps = appsArray
                return
            }
            // fallbacks: try extracting "apps" key manually
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let appsFragment = jsonObject["apps"] {
                let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                let appsArray = try decoder.decode([AltApp].self, from: fragmentData)
                self.apps = appsArray
                return
            }
            throw NSError(domain: "RepoFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON format"])
        } catch {
            self.errorMessage = "Failed to load: \(error.localizedDescription)"
            self.apps = []
        }
    }
    
    func refresh() {
        Task { await load() }
    }
}

// MARK: - AppsView (no NavigationView)
public struct AppsView: View {
    @StateObject private var vm: RepoViewModel
    
    /// Provide custom repo URL if you want (defaults to https://repository.apptesters.org/)
    public init(repoURL: URL = URL(string: "https://repository.apptesters.org/")!) {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURL: repoURL))
    }
    
    public var body: some View {
        Group {
            if vm.isLoading && vm.apps.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading apps...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else if let error = vm.errorMessage, vm.apps.isEmpty {
                VStack(spacing: 12) {
                    Text("Error")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { vm.refresh() }
                        .padding(.top, 8)
                }
                .padding()
            } else {
                List(vm.apps) { app in
                    // parent NavigationStack handles navigation; provide a NavigationLink to a detail view
                    NavigationLink(value: app) {
                        AppRowView(app: app)
                    }
                }
                .listStyle(.plain)
                .refreshable { vm.refresh() } // iOS 15+
                // If you don't want navigation links, swap NavigationLink -> Button/openURL as you prefer.
                .navigationDestination(for: AltApp.self) { app in
                    AppDetailView(app: app)
                }
            }
        }
        // Do not set navigationTitle here — your parent already does that
    }
}

// MARK: - Row View
private struct AppRowView: View {
    let app: AltApp
    
    var body: some View {
        HStack(spacing: 12) {
            if let iconURL = app.iconURL {
                AsyncImage(url: iconURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 48, height: 48)
                    case .success(let image):
                        image.resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(radius: 1, y: 1)
                    case .failure:
                        Image(systemName: "app")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .foregroundColor(.secondary)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if let dev = app.developerName {
                    Text(dev)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let size = app.versions?.first?.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Simple Detail View
private struct AppDetailView: View {
    let app: AltApp
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let iconURL = app.iconURL {
                    AsyncImage(url: iconURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case .success(let image):
                            image.resizable()
                                .scaledToFit()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        default:
                            Image(systemName: "app")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 100, height: 100)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.name)
                        .font(.title2)
                        .bold()
                    if let dev = app.developerName {
                        Text(dev)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let desc = app.localizedDescription {
                        Text(desc)
                            .font(.body)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                if let version = app.versions?.first {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Latest")
                            .font(.headline)
                        HStack {
                            VStack(alignment: .leading) {
                                if let v = version.version { Text("Version: \(v)") }
                                if let b = version.buildVersion { Text("Build: \(b)") }
                                if let min = version.minOSVersion { Text("Min iOS: \(min)") }
                                if let size = version.size {
                                    Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                
                if let url = app.latestDownloadURL {
                    Button(action: { openURL(url) }) {
                        Label("Open download URL", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 20)
            }
            .padding(.top)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

}
