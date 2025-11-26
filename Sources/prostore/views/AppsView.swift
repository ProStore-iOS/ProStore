import SwiftUI
import Combine
import Foundation

// MARK: - Models
public struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let apps: [AltApp]?
}

public struct AppVersion: Decodable {
    let version: String?
    let date: String?
    let downloadURL: URL?
    let size: Int?
    let minOSVersion: String?
    let localizedDescription: String?
}

public struct AltApp: Decodable, Identifiable {
    public var id: String { bundleIdentifier }
    public let name: String
    public let bundleIdentifier: String
    public let developerName: String?
    public let subtitle: String?
    public let iconURL: URL?
    public let localizedDescription: String?
    public let versions: [AppVersion]?
    public let screenshotURLs: [URL]?
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

// MARK: - RetryAsyncImage (stable layout + retry)
struct RetryAsyncImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL?
    let maxAttempts: Int
    let size: CGSize?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    let failure: () -> Failure

    @State private var currentAttempt: Int = 0
    @State private var retryTrigger: UUID = UUID()

    private var modifiedURL: URL? {
        guard let url = url else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // inject attempt param so AsyncImage re-fetches when attempt changes
        var query = components?.queryItems ?? []
        query.removeAll(where: { $0.name == "retryAttempt" })
        query.append(URLQueryItem(name: "retryAttempt", value: "\(currentAttempt)"))
        components?.queryItems = query
        return components?.url
    }

    init(
        url: URL?,
        size: CGSize? = nil,
        maxAttempts: Int = 3,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.size = size
        self.maxAttempts = maxAttempts
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        let frameView = Group {
            if let modifiedURL = modifiedURL {
                AsyncImage(url: modifiedURL) { phase in
                    switch phase {
                    case .empty:
                        placeholder()
                    case .success(let image):
                        content(image)
                    case .failure:
                        // If we still have attempts left, show placeholder and schedule a retry
                        if currentAttempt < maxAttempts - 1 {
                            placeholder()
                                .task {
                                    // small delay to avoid tight loop and give network a moment
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    await MainActor.run {
                                        currentAttempt += 1
                                        retryTrigger = UUID()
                                    }
                                }
                        } else {
                            failure()
                        }
                    @unknown default:
                        placeholder()
                    }
                }
            } else {
                failure()
            }
        }

        if let size = size {
            frameView
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            frameView
        }
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

            // Search Bar (hidden during initial load)
            if !(vm.isLoading && vm.apps.isEmpty) {
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
            }

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
    private let iconSize = CGSize(width: 48, height: 48)

    var body: some View {
        HStack(spacing: 12) {
            // Icon column: always reserves space so text doesn't shift
            ZStack {
                // stable background so we always have a visible placeholder area
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: iconSize.width, height: iconSize.height)

                if let iconURL = app.iconURL {
                    RetryAsyncImage(
                        url: iconURL,
                        size: iconSize,
                        maxAttempts: 3,
                        content: { image in
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: iconSize.width, height: iconSize.height)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        },
                        placeholder: {
                            ProgressView()
                                .frame(width: iconSize.width, height: iconSize.height)
                        },
                        failure: {
                            Image(systemName: "app")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                                .foregroundColor(.secondary)
                        }
                    )
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: iconSize.width, height: iconSize.height) // crucial: fixed width

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1) // prevent truncation due to flexible spacing
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

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
