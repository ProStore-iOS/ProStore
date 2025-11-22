import SwiftUI
import Combine

// MARK: - Models (decodable for AltStore source format)
struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let apps: [AltApp]?
}

struct AltApp: Decodable, Identifiable, Equatable {
    // Use bundleIdentifier as stable id
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let iconURL: URL?
    let versions: [AppVersion]?
    
    // A convenience computed property for a primary download URL (if present on the latest version)
    var latestDownloadURL: URL? {
        versions?.first?.downloadURL
    }
}

struct AppVersion: Decodable, Equatable {
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
    
    /// Load JSON and decode apps. Tries both `{ "apps": [...] }` and direct `[App]` shapes.
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            var request = URLRequest(url: sourceURL)
            // Some repos expect a GET; set a reasonable user-agent
            request.setValue("AppTestersListView/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "RepoFetcher", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            
            let decoder = JSONDecoder()
            // First try decoding top-level AltSource (common altstore format)
            if let source = try? decoder.decode(AltSource.self, from: data), let apps = source.apps {
                self.apps = apps
                return
            }
            
            // Fallback: some repos publish a raw array of apps
            if let appsArray = try? decoder.decode([AltApp].self, from: data) {
                self.apps = appsArray
                return
            }
            
            // Another fallback: some repos wrap apps in a top-level dictionary under other keys
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // try to extract "apps" key and re-decode that fragment
                if let appsFragment = jsonObject["apps"] {
                    let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                    let appsArray = try decoder.decode([AltApp].self, from: fragmentData)
                    self.apps = appsArray
                    return
                }
            }
            
            throw NSError(domain: "RepoFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON format."])
            
        } catch {
            self.errorMessage = "Failed to load repository: \(error.localizedDescription)"
            self.apps = []
        }
    }
    
    /// Public method to refresh on demand
    func refresh() {
        Task { await load() }
    }
}

// MARK: - The SwiftUI View (search bar added; works without NavigationView)
public struct AppsView: View {
    @StateObject private var vm: RepoViewModel
    
    // Search state
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool
    
    // Public initializer so you can pass a custom repository URL (defaults to user's provided URL)
    public init(repoURL: URL = URL(string: "https://repository.apptesters.org/")!) {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURL: repoURL))
    }
    
    // Filtered apps based on search text
    private var filteredApps: [AltApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vm.apps }
        let lowered = query.lowercased()
        return vm.apps.filter { app in
            if app.name.lowercased().contains(lowered) { return true }
            if app.bundleIdentifier.lowercased().contains(lowered) { return true }
            if let dev = app.developerName, dev.lowercased().contains(lowered) { return true }
            if let sub = app.subtitle, sub.lowercased().contains(lowered) { return true }
            return false
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Search bar (always visible, works outside NavigationView)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search apps, developer or bundle ID", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($searchFieldFocused)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.regularMaterial) // nice subtle background
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Content
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
                    List(filteredApps) { app in
                        AppRowView(app: app)
                    }
                    .listStyle(PlainListStyle())
                    .refreshable { vm.refresh() }
                }
            }
            .padding(.top, 8)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh repository")
            }
        }
        .padding(.horizontal, 0)
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
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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