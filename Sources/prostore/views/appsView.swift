import SwiftUI
import Combine

// MARK: - Models
struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let apps: [AltApp]?
}

struct AltApp: Decodable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let iconURL: URL?
    let versions: [AppVersion]?

    var latestDownloadURL: URL? { versions?.first?.downloadURL }
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

// MARK: - Image Cache
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var cache: [URL: Image] = [:]
    
    func image(for url: URL) -> Image? { cache[url] }
    func set(_ image: Image, for url: URL) { cache[url] = image }
}

// MARK: - ViewModel
@MainActor
final class RepoViewModel: ObservableObject {
    @Published private(set) var apps: [AltApp] = []
    @Published private(set) var filteredApps: [AltApp] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    @Published var searchText: String = "" {
        didSet { debounceSearch() }
    }
    
    private var searchTask: Task<Void, Never>?
    private let sourceURL: URL
    
    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        Task { await load() }
    }
    
    /// Load apps
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            var request = URLRequest(url: sourceURL)
            request.setValue("AppTestersListView/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "RepoFetcher", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            
            let decoder = JSONDecoder()
            let newApps: [AltApp]
            
            if let source = try? decoder.decode(AltSource.self, from: data), let apps = source.apps {
                newApps = apps
            } else if let appsArray = try? decoder.decode([AltApp].self, from: data) {
                newApps = appsArray
            } else if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let appsFragment = jsonObject["apps"] {
                let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                newApps = try decoder.decode([AltApp].self, from: fragmentData)
            } else {
                throw NSError(domain: "RepoFetcher", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON format."])
            }
            
            // Diff update to avoid full redraw
            if newApps != apps { apps = newApps }
            filterApps()
            
        } catch {
            self.errorMessage = "Failed to load repository: \(error.localizedDescription)"
            self.apps = []
            self.filteredApps = []
        }
    }
    
    func refresh() { Task { await load() } }
    
    private func debounceSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            await self?.filterApps()
        }
    }
    
    private func filterApps() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredApps = apps
            return
        }
        filteredApps = apps.filter { app in
            app.name.lowercased().contains(query)
            || app.bundleIdentifier.lowercased().contains(query)
            || app.developerName?.lowercased().contains(query) == true
            || app.subtitle?.lowercased().contains(query) == true
        }
    }
}

// MARK: - View
public struct AppsView: View {
    @StateObject private var vm: RepoViewModel
    @FocusState private var searchFieldFocused: Bool
    
    public init(repoURL: URL = URL(string: "https://repository.apptesters.org/")!) {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURL: repoURL))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .padding(.horizontal)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.refresh() }) { Image(systemName: "arrow.clockwise") }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search apps, developer or bundle ID", text: $vm.searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($searchFieldFocused)
                .submitLabel(.search)
            if !vm.searchText.isEmpty {
                Button(action: { vm.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .cornerRadius(10)
        .padding(.top, 8)
    }
    
    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.apps.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading apps...").font(.subheadline).foregroundColor(.secondary)
            }.padding()
        } else if let error = vm.errorMessage, vm.apps.isEmpty {
            VStack(spacing: 12) {
                Text("Error").font(.headline)
                Text(error).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Retry") { vm.refresh() }.padding(.top, 8)
            }.padding()
        } else {
            ScrollView {
                LazyVStack {
                    ForEach(vm.filteredApps) { app in
                        AppRowView(app: app)
                            .transition(.opacity)
                    }
                }
            }
            .refreshable { vm.refresh() }
        }
    }
}

// MARK: - Row
private struct AppRowView: View {
    let app: AltApp
    
    var body: some View {
        HStack(spacing: 12) {
            if let iconURL = app.iconURL {
                if let cached = ImageCache.shared.image(for: iconURL) {
                    cached
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    AsyncImage(url: iconURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().frame(width: 48, height: 48)
                        case .success(let image):
                            let img = image.resizable()
                            ImageCache.shared.set(img, for: iconURL)
                            img.scaledToFill().frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            Image(systemName: "app").resizable().scaledToFit()
                                .frame(width: 36, height: 36).foregroundColor(.secondary)
                        @unknown default: EmptyView()
                        }
                    }
                }
            } else {
                Image(systemName: "app").resizable().scaledToFit()
                    .frame(width: 36, height: 36).foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                } else if let dev = app.developerName {
                    Text(dev).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
            }
            
            Spacer()
            
            if let size = app.versions?.first?.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}