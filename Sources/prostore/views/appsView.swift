import SwiftUI
import Combine

// MARK: - Models
struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let apps: [AltApp]?
}

struct AppVersion: Decodable {
    let version: String?
    let date: String?
    let downloadURL: URL?
    let size: Int?
    let minOSVersion: String?
    let localizedDescription: String?
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
    let screenshotURLs: [URL]?
}

// MARK: - ViewModel
@MainActor
final class RepoViewModel: ObservableObject {
    @Published var apps: [AltApp] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    private let sourceURLs: [URL]   // <-- multiple sources
    
    init(sourceURLs: [URL]) {
        self.sourceURLs = sourceURLs
        Task { await loadAllSources() }
    }
    
    func loadAllSources() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        var combinedApps: [AltApp] = []
        var errors: [String] = []
        
        for url in sourceURLs {
            do {
                var request = URLRequest(url: url)
                request.setValue("AppTestersListView/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: "RepoFetcher", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }
                
                let decoder = JSONDecoder()
                
                if let source = try? decoder.decode(AltSource.self, from: data), let apps = source.apps {
                    combinedApps.append(contentsOf: apps)
                    continue
                }
                
                if let appsArray = try? decoder.decode([AltApp].self, from: data) {
                    combinedApps.append(contentsOf: appsArray)
                    continue
                }
                
                if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let appsFragment = jsonObject["apps"] {
                    let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                    let appsArray = try decoder.decode([AltApp].self, from: fragmentData)
                    combinedApps.append(contentsOf: appsArray)
                    continue
                }
                
                throw NSError(domain: "RepoFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON format."])
                
            } catch {
                errors.append("Failed \(url): \(error.localizedDescription)")
            }
        }
        
        self.apps = combinedApps
        if !errors.isEmpty {
            self.errorMessage = errors.joined(separator: "\n")
        }
    }
    
    func refresh() {
        Task { await loadAllSources() }
    }
}

// MARK: - AppsView
public struct AppsView: View {
    @StateObject private var vm: RepoViewModel
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedApp: AltApp? = nil
    
    public init(repoURLs: [URL] = [URL(string: "https://repository.apptesters.org/")!]) {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURLs: repoURLs))
    }
    
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
            
            // Search Bar
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
            .background(.regularMaterial)
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
                        Button {
                            selectedApp = app
                        } label: {
                            AppRowView(app: app)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(PlainListStyle())
                    .refreshable { vm.refresh() }
                }
            }
            .padding(.top, 8)
        }
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { vm.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh repository")
            }
        }
    }
}

// MARK: - AppRowView
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
                            .clipShape(RoundedRectangle(cornerRadius: 10))
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

// MARK: - AppDetailView
private struct AppDetailView: View {
    let app: AltApp
    
    private var latestVersion: AppVersion? {
        app.versions?.first
    }
    
    private func formatSize(_ size: Int?) -> String {
        guard let size = size else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    
    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString, let date = ISO8601DateFormatter().date(from: dateString) else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // App Header
                HStack(alignment: .top, spacing: 16) {
                    if let iconURL = app.iconURL {
                        AsyncImage(url: iconURL) { phase in
                            switch phase {
                            case .empty: ProgressView().frame(width: 80, height: 80)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            case .failure:
                                Image(systemName: "app")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 60, height: 60)
                                    .foregroundColor(.secondary)
                            @unknown default: EmptyView()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title2)
                            .bold()
                        if let dev = app.developerName {
                            Text(dev)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // General description
                if let generalDesc = app.localizedDescription, generalDesc != latestVersion?.localizedDescription {
                    Text(generalDesc)
                }
                
                // What's New
                if let latest = latestVersion, let latestDesc = latest.localizedDescription,
                   latestDesc != app.localizedDescription {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What's New?")
                            .font(.headline)
                        Text(latestDesc)
                    }
                }
                
                // Version info
                if let latest = latestVersion {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Version:").bold(); Text(latest.version ?? "Unknown") }
                        HStack { Text("Released:").bold(); Text(formatDate(latest.date)) }
                        HStack { Text("Size:").bold(); Text(formatSize(latest.size)) }
                        HStack { Text("Min OS:").bold(); Text(latest.minOSVersion ?? "Unknown") }
                    }
                }
                
                // Screenshots (from general app)
                if let screenshots = app.screenshotURLs, !screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(screenshots, id: \.self) { url in
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty: ProgressView()
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 200)
                                            .cornerRadius(10)
                                    case .failure:
                                        Image(systemName: "photo")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 200)
                                    @unknown default: EmptyView()
                                    }
                                }
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}