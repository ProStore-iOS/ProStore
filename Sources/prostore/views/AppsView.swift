import SwiftUI
import Combine
import Foundation

// MARK: - Models
public struct AltSource: Decodable {
    let name: String?
    let subtitle: String?
    let iconURL: URL?
    let META: SourceMeta?
    let apps: [AppRaw]?

    struct SourceMeta: Decodable {
        let repoName: String?
        let repoIcon: String?
    }
}

// Raw app struct to support multiple JSON key variations from different feeds
public struct AppRaw: Decodable {
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let subtitle: String?
    let iconURLString: String?
    let localizedDescription: String?
    let versions: [AppVersion]?
    let screenshotURLs: [URL]?

    // top-level app fields present in your example JSON
    let size: Int?
    let versionDate: String?
    let fullDate: String?
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier
        case bundleID
        case developerName
        case subtitle
        case iconURL
        case icon
        case localizedDescription
        case versions
        case screenshotURLs
        case size
        case versionDate
        case fullDate
        case downloadURL
        case down
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // name
        self.name = try container.decode(String.self, forKey: .name)

        // bundleIdentifier: try bundleIdentifier then bundleID
        if let bid = try? container.decode(String.self, forKey: .bundleIdentifier) {
            self.bundleIdentifier = bid
        } else if let bid2 = try? container.decode(String.self, forKey: .bundleID) {
            self.bundleIdentifier = bid2
        } else {
            // fallback (should not occur if JSON has an ID)
            self.bundleIdentifier = UUID().uuidString
        }

        self.developerName = try? container.decodeIfPresent(String.self, forKey: .developerName)
        self.subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)

        // icon keys: iconURL or icon
        if let iconStr = try? container.decodeIfPresent(String.self, forKey: .iconURL) {
            self.iconURLString = iconStr
        } else if let iconStr2 = try? container.decodeIfPresent(String.self, forKey: .icon) {
            self.iconURLString = iconStr2
        } else {
            self.iconURLString = nil
        }

        self.localizedDescription = try? container.decodeIfPresent(String.self, forKey: .localizedDescription)

        // versions and screenshotURLs are optional, decode normally
        self.versions = try? container.decodeIfPresent([AppVersion].self, forKey: .versions)
        self.screenshotURLs = try? container.decodeIfPresent([URL].self, forKey: .screenshotURLs)

        // other top-levels
        self.size = try? container.decodeIfPresent(Int.self, forKey: .size)
        self.versionDate = try? container.decodeIfPresent(String.self, forKey: .versionDate)
        self.fullDate = try? container.decodeIfPresent(String.self, forKey: .fullDate)

        // downloadURL keys: downloadURL or down
        if let dl = try? container.decodeIfPresent(String.self, forKey: .downloadURL) {
            self.downloadURL = dl
        } else if let dl2 = try? container.decodeIfPresent(String.self, forKey: .down) {
            self.downloadURL = dl2
        } else {
            self.downloadURL = nil
        }
    }
}

public struct AppVersion: Decodable {
    let version: String?
    let date: String?
    let downloadURL: String?
    let size: Int?
    let minOSVersion: String?
    let localizedDescription: String?
}

// Final AltApp used by the UI (includes repositoryName)
public struct AltApp: Identifiable, Equatable {
    public var id: String { bundleIdentifier }

    public let name: String
    public let bundleIdentifier: String
    public let developerName: String?
    public let subtitle: String?
    public let iconURL: URL?
    public let localizedDescription: String?
    public let versions: [AppVersion]?
    public let screenshotURLs: [URL]?
    public let size: Int?
    public let versionDate: String?
    public let fullDate: String?
    public let downloadURL: URL?
    public let repositoryName: String?
    public static func == (lhs: AltApp, rhs: AltApp) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier &&
               lhs.name == rhs.name &&
               lhs.developerName == rhs.developerName &&
               lhs.subtitle == rhs.subtitle &&
               lhs.iconURL?.absoluteString == rhs.iconURL?.absoluteString &&
               lhs.localizedDescription == rhs.localizedDescription &&
               lhs.size == rhs.size &&
               lhs.versionDate == rhs.versionDate &&
               lhs.fullDate == rhs.fullDate &&
               lhs.downloadURL?.absoluteString == rhs.downloadURL?.absoluteString &&
               lhs.repositoryName == rhs.repositoryName
    }
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

                // 1) If top-level AltSource that contains "apps"
                if let source = try? decoder.decode(AltSource.self, from: data), let rawApps = source.apps {
                    let repoName = source.META?.repoName ?? source.name
                    let mapped = rawApps.map { raw -> AltApp in
                        AltApp(
                            name: raw.name,
                            bundleIdentifier: raw.bundleIdentifier,
                            developerName: raw.developerName,
                            subtitle: raw.subtitle,
                            iconURL: raw.iconURLString.flatMap { URL(string: $0) },
                            localizedDescription: raw.localizedDescription,
                            versions: raw.versions,
                            screenshotURLs: raw.screenshotURLs,
                            size: raw.size,
                            versionDate: raw.versionDate,
                            fullDate: raw.fullDate,
                            downloadURL: raw.downloadURL.flatMap { URL(string: $0) },
                            repositoryName: repoName
                        )
                    }
                    combinedApps.append(contentsOf: mapped)
                    continue
                }

                // 2) If JSON is an array of app objects (raw)
                if let rawArray = try? decoder.decode([AppRaw].self, from: data) {
                    let mapped = rawArray.map { raw -> AltApp in
                        AltApp(
                            name: raw.name,
                            bundleIdentifier: raw.bundleIdentifier,
                            developerName: raw.developerName,
                            subtitle: raw.subtitle,
                            iconURL: raw.iconURLString.flatMap { URL(string: $0) },
                            localizedDescription: raw.localizedDescription,
                            versions: raw.versions,
                            screenshotURLs: raw.screenshotURLs,
                            size: raw.size,
                            versionDate: raw.versionDate,
                            fullDate: raw.fullDate,
                            downloadURL: raw.downloadURL.flatMap { URL(string: $0) },
                            repositoryName: nil
                        )
                    }
                    combinedApps.append(contentsOf: mapped)
                    continue
                }

                // 3) If JSON has a top-level "apps" property but different wrapper
                if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let appsFragment = jsonObject["apps"] {
                    let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                    let rawArray = try decoder.decode([AppRaw].self, from: fragmentData)
                    let mapped = rawArray.map { raw -> AltApp in
                        AltApp(
                            name: raw.name,
                            bundleIdentifier: raw.bundleIdentifier,
                            developerName: raw.developerName,
                            subtitle: raw.subtitle,
                            iconURL: raw.iconURLString.flatMap { URL(string: $0) },
                            localizedDescription: raw.localizedDescription,
                            versions: raw.versions,
                            screenshotURLs: raw.screenshotURLs,
                            size: raw.size,
                            versionDate: raw.versionDate,
                            fullDate: raw.fullDate,
                            downloadURL: raw.downloadURL.flatMap { URL(string: $0) },
                            repositoryName: nil
                        )
                    }
                    combinedApps.append(contentsOf: mapped)
                    continue
                }

                throw NSError(domain: "RepoFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON format."])

            } catch {
                errors.append("Failed \(url): \(error.localizedDescription)")
            }
        }

        // Optionally dedupe by bundleIdentifier (keep first occurrence)
        var seen: Set<String> = []
        let deduped = combinedApps.filter { app in
            if seen.contains(app.bundleIdentifier) { return false }
            seen.insert(app.bundleIdentifier)
            return true
        }

        self.apps = deduped
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
                        if currentAttempt < maxAttempts - 1 {
                            placeholder()
                                .task {
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

// MARK: - Sorting
enum SortOption: String, CaseIterable, Identifiable {
    case nameAZ = "Name: A - Z"
    case nameZA = "Name: Z - A"
    case repoAZ = "Repository"
    case dateNewOld = "Date: New - Old"
    case dateOldNew = "Date: Old - New"
    case sizeLowHigh = "Size: Low - High"
    case sizeHighLow = "Size: High - Low"

    var id: String { self.rawValue }
}

// Helper for parsing dates
fileprivate func appDate(for app: AltApp) -> Date? {
    // Prefer fullDate (format like "20251126100919"), else try versionDate like "2025-11-26"
    if let full = app.fullDate {
        // try parse yyyyMMddHHmmss or yyyyMMdd
        let len = full.count
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if len >= 14 {
            formatter.dateFormat = "yyyyMMddHHmmss"
        } else if len == 8 {
            formatter.dateFormat = "yyyyMMdd"
        } else {
            // fallback attempt
            formatter.dateFormat = "yyyyMMddHHmmss"
        }
        if let d = formatter.date(from: full) { return d }
    }

    if let vd = app.versionDate {
        let formatter = ISO8601DateFormatter()
        // attempt strict "yyyy-MM-dd"
        if let date = formatter.date(from: vd + "T00:00:00Z") {
            return date
        }
        // fallback try DateFormatter
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: vd) { return d }
    }

    return nil
}

// MARK: - AppsView
public struct AppsView: View {
    @StateObject private var vm: RepoViewModel
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedApp: AltApp? = nil
    @State private var sortOption: SortOption = .nameAZ

    /// Which repositories are expanded (by repository key string).
    @State private var expandedRepos: Set<String> = []

    public init(repoURLs: [URL] = [URL(string: "https://repository.apptesters.org/")!]) {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURLs: repoURLs))
    }

    private var sortedApps: [AltApp] {
        switch sortOption {
        case .nameAZ:
            return vm.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameZA:
            return vm.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .repoAZ:
            return vm.apps.sorted {
                let aRepo = $0.repositoryName ?? ""
                let bRepo = $1.repositoryName ?? ""
                if aRepo.localizedCaseInsensitiveCompare(bRepo) == .orderedSame {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return aRepo.localizedCaseInsensitiveCompare(bRepo) == .orderedAscending
            }
        case .dateNewOld:
            return vm.apps.sorted {
                let da = appDate(for: $0) ?? Date.distantPast
                let db = appDate(for: $1) ?? Date.distantPast
                return da > db
            }
        case .dateOldNew:
            return vm.apps.sorted {
                let da = appDate(for: $0) ?? Date.distantPast
                let db = appDate(for: $1) ?? Date.distantPast
                return da < db
            }
        case .sizeLowHigh:
            return vm.apps.sorted {
                let sa = $0.size ?? Int.max
                let sb = $1.size ?? Int.max
                return sa < sb
            }
        case .sizeHighLow:
            return vm.apps.sorted {
                let sa = $0.size ?? Int.min
                let sb = $1.size ?? Int.min
                return sa > sb
            }
        }
    }

    private var filteredApps: [AltApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedApps }
        let lowered = query.lowercased()
        return sortedApps.filter { app in
            if app.name.lowercased().contains(lowered) { return true }
            if app.bundleIdentifier.lowercased().contains(lowered) { return true }
            if let dev = app.developerName, dev.lowercased().contains(lowered) { return true }
            if let sub = app.subtitle, sub.lowercased().contains(lowered) { return true }
            if let repo = app.repositoryName, repo.lowercased().contains(lowered) { return true }
            return false
        }
    }

    private var groupedApps: [String: [AltApp]] {
        Dictionary(grouping: filteredApps, by: { $0.repositoryName ?? "Unknown Repository" })
    }

    private var orderedRepoKeys: [String] {
        let keys = Array(groupedApps.keys)
        if sortOption == .repoAZ {
            return keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            var order: [String] = []
            for app in sortedApps {
                let key = app.repositoryName ?? "Unknown Repository"
                if !order.contains(key) { order.append(key) }
            }
            for k in keys where !order.contains(k) {
                order.append(k)
            }
            return order
        }
    }

    // MARK: - View pieces

    @ViewBuilder private var searchAndSortBar: some View {
        if !(vm.isLoading && vm.apps.isEmpty) {
            HStack(spacing: 8) {
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
                .frame(maxWidth: .infinity)

                Picker(selection: $sortOption, label: Label("Sort", systemImage: "arrow.up.arrow.down")) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .cornerRadius(10)
                .frame(minWidth: 170)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading apps...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    @ViewBuilder private func errorView(_ error: String) -> some View {
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
    }

    @ViewBuilder private func repoHeader(_ repoKey: String) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.spring()) {
                    if expandedRepos.contains(repoKey) {
                        expandedRepos.remove(repoKey)
                    } else {
                        expandedRepos.insert(repoKey)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: expandedRepos.contains(repoKey) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repoKey)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("\(groupedApps[repoKey]?.count ?? 0) app\( (groupedApps[repoKey]?.count ?? 0) == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func repoSection(_ repoKey: String) -> some View {
        // NOTE: If collapsed, show header only (no app rows)
        Section {
            if expandedRepos.contains(repoKey) {
                ForEach(groupedApps[repoKey] ?? []) { app in
                    Button { selectedApp = app } label: { AppRowView(app: app) }
                        .buttonStyle(.plain)
                }
            } else {
                // collapsed: intentionally show no rows
                EmptyView()
            }
        } header: {
            repoHeader(repoKey)
        }
    }

    @ViewBuilder private var listView: some View {
        if sortOption == .repoAZ {
            List {
                ForEach(orderedRepoKeys, id: \.self) { repoKey in
                    repoSection(repoKey)
                }
            }
            .listStyle(PlainListStyle())
            .refreshable { vm.refresh() }
        } else {
            // flat list for all other sort modes
            List {
                ForEach(filteredApps) { app in
                    Button { selectedApp = app } label: { AppRowView(app: app) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(PlainListStyle())
            .refreshable { vm.refresh() }
        }
    }

    // MARK: - Body
    public var body: some View {
        VStack(spacing: 0) {
            searchAndSortBar

            Group {
                if vm.isLoading && vm.apps.isEmpty {
                    loadingView
                } else if let error = vm.errorMessage, vm.apps.isEmpty {
                    errorView(error)
                } else {
                    listView
                }
            }
            .padding(.top, 8)
        }
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: { vm.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                Button(action: {
                    withAnimation(.spring()) { expandedRepos = Set(orderedRepoKeys) }
                }) {
                    Image(systemName: "rectangle.expand.vertical")
                }
                Button(action: {
                    withAnimation(.spring()) { expandedRepos.removeAll() }
                }) {
                    Image(systemName: "rectangle.compress.vertical")
                }
            }
        }
        .onAppear {
            expandedRepos = (sortOption == .repoAZ) ? Set(orderedRepoKeys) : []
        }
        .onChange(of: vm.apps) { _ in
            if sortOption == .repoAZ {
                expandedRepos = Set(orderedRepoKeys)
            } else {
                expandedRepos.removeAll()
            }
        }
        .onChange(of: searchText) { _ in
            if sortOption == .repoAZ {
                expandedRepos.formUnion(orderedRepoKeys)
            }
        }
        .onChange(of: sortOption) { newOption in
            if newOption == .repoAZ {
                expandedRepos.formUnion(orderedRepoKeys)
            } else {
                expandedRepos.removeAll()
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
                } else if let repo = app.repositoryName {
                    Text(repo)
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