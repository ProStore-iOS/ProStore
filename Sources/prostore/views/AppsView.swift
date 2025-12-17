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
// MARK: - CachedApp
public struct CachedApp: Identifiable {
    public var id: String { app.id }
    public let app: AltApp
    // precomputed fields for fast filtering/sorting
    public let nameLower: String
    public let bundleLower: String
    public let devLower: String?
    public let subtitleLower: String?
    public let repoName: String
    public let parsedDate: Date?
    public let sizeValue: Int?
    public init(app: AltApp) {
        self.app = app
        self.nameLower = app.name.lowercased()
        self.bundleLower = app.bundleIdentifier.lowercased()
        self.devLower = app.developerName?.lowercased()
        self.subtitleLower = app.subtitle?.lowercased()
        self.repoName = app.repositoryName ?? "Unknown Repository"
        self.parsedDate = appDate(for: app) // reuse helper
        self.sizeValue = app.size
    }
}
// MARK: - ViewModel (updated)
@MainActor
final class RepoViewModel: ObservableObject {
    // raw apps
    @Published private(set) var apps: [AltApp] = []
    // cached wrapper for each app (pre-parsed)
    @Published private(set) var cachedApps: [CachedApp] = []
    // the final list that UI will use (already filtered + sorted)
    @Published private(set) var displayedCachedApps: [CachedApp] = []
    // loading, error
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    // user-controllable search & sort
    @Published var searchQuery: String = ""
    @Published var selectedSort: SortOption = .nameAZ

    private var sourceURLs: [URL] // <-- multiple sources
    private var cancellables = Set<AnyCancellable>()

    init(sourceURLs: [URL]) {
        self.sourceURLs = sourceURLs
        // Combine pipeline: debounce search/sort, react to cachedApps changes
        Publishers.CombineLatest3($searchQuery.removeDuplicates(),
                                  $selectedSort.removeDuplicates(by: { $0.rawValue == $1.rawValue }),
                                  $cachedApps)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main) // debounce both search & sort changes
            .receive(on: DispatchQueue.global(qos: .userInitiated)) // process filtering/sorting off main
            .map { (query, sort, cached) -> [CachedApp] in
                let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let filtered: [CachedApp]
                if q.isEmpty {
                    filtered = cached
                } else {
                    filtered = cached.filter { c in
                        if c.nameLower.contains(q) { return true }
                        if c.bundleLower.contains(q) { return true }
                        if let d = c.devLower, d.contains(q) { return true }
                        if let s = c.subtitleLower, s.contains(q) { return true }
                        if c.repoName.lowercased().contains(q) { return true }
                        return false
                    }
                }
                // Sorting using cached fields (fast)
                let sorted: [CachedApp]
                switch sort {
                case .nameAZ:
                    sorted = filtered.sorted {
                        let pa = ( $0.nameLower.first?.isLetter == true ? 0 :
                                   $0.nameLower.first?.isNumber == true ? 1 :
                                   ($0.nameLower.first?.isPunctuation == true || $0.nameLower.first?.isSymbol == true) ? 2 : 3)
                        let pb = ( $1.nameLower.first?.isLetter == true ? 0 :
                                   $1.nameLower.first?.isNumber == true ? 1 :
                                   ($1.nameLower.first?.isPunctuation == true || $1.nameLower.first?.isSymbol == true) ? 2 : 3)
                        return pa != pb ? pa < pb : $0.nameLower < $1.nameLower
                    }
                case .nameZA:
                    sorted = filtered.sorted {
                        let pa = ( $0.nameLower.first?.isLetter == true ? 0 :
                                   $0.nameLower.first?.isNumber == true ? 1 :
                                   ($0.nameLower.first?.isPunctuation == true || $0.nameLower.first?.isSymbol == true) ? 2 : 3)
                        let pb = ( $1.nameLower.first?.isLetter == true ? 0 :
                                   $1.nameLower.first?.isNumber == true ? 1 :
                                   ($1.nameLower.first?.isPunctuation == true || $1.nameLower.first?.isSymbol == true) ? 2 : 3)
                        return pa != pb ? pa < pb : $0.nameLower > $1.nameLower
                    }
                case .repoAZ:
                    // sort by repo then name
                    sorted = filtered.sorted {
                        if $0.repoName.localizedCaseInsensitiveCompare($1.repoName) == .orderedSame {
                            return $0.nameLower < $1.nameLower
                        }
                        return $0.repoName.localizedCaseInsensitiveCompare($1.repoName) == .orderedAscending
                    }
                case .dateNewOld:
                    sorted = filtered.sorted {
                        let da = $0.parsedDate ?? Date.distantPast
                        let db = $1.parsedDate ?? Date.distantPast
                        return da > db
                    }
                case .dateOldNew:
                    sorted = filtered.sorted {
                        let da = $0.parsedDate ?? Date.distantPast
                        let db = $1.parsedDate ?? Date.distantPast
                        return da < db
                    }
                case .sizeLowHigh:
                    sorted = filtered.sorted {
                        let sa = $0.sizeValue ?? Int.max
                        let sb = $1.sizeValue ?? Int.max
                        return sa < sb
                    }
                case .sizeHighLow:
                    sorted = filtered.sorted {
                        let sa = $0.sizeValue ?? Int.min
                        let sb = $1.sizeValue ?? Int.min
                        return sa > sb
                    }
                }
                return sorted
            }
            .receive(on: RunLoop.main) // publish results to main
            .sink { [weak self] result in
                self?.displayedCachedApps = result
            }
            .store(in: &cancellables)

        Task { await loadAllSources() }
    }

    func loadAllSources() async {
        await MainActor.run { isLoading = true; errorMessage = nil }
        defer { Task { await MainActor.run { self.isLoading = false } } }
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

                // Case 1: AltSource with apps property
                if let source = try? decoder.decode(AltSource.self, from: data), let rawApps = source.apps {
                    let repoName = source.META?.repoName ?? source.name
                    let mapped = rawApps.map { raw -> AltApp in
                        // prefer download URL from versions (first non-nil), else fallback to top-level downloadURL
                        let preferredDownloadString = raw.versions?.compactMap { $0.downloadURL }.first ?? raw.downloadURL
                        let preferredDownloadURL = preferredDownloadString.flatMap { URL(string: $0) }

                        return AltApp(
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
                            downloadURL: preferredDownloadURL,
                            repositoryName: repoName
                        )
                    }
                    combinedApps.append(contentsOf: mapped)
                    continue
                }

                // Case 2: top-level array of AppRaw
                if let rawArray = try? decoder.decode([AppRaw].self, from: data) {
                    let mapped = rawArray.map { raw -> AltApp in
                        let preferredDownloadString = raw.versions?.compactMap { $0.downloadURL }.first ?? raw.downloadURL
                        let preferredDownloadURL = preferredDownloadString.flatMap { URL(string: $0) }

                        return AltApp(
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
                            downloadURL: preferredDownloadURL,
                            repositoryName: nil
                        )
                    }
                    combinedApps.append(contentsOf: mapped)
                    continue
                }

                // Case 3: JSON object with "apps" fragment
                if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let appsFragment = jsonObject["apps"] {
                    let fragmentData = try JSONSerialization.data(withJSONObject: appsFragment)
                    let rawArray = try decoder.decode([AppRaw].self, from: fragmentData)
                    let mapped = rawArray.map { raw -> AltApp in
                        let preferredDownloadString = raw.versions?.compactMap { $0.downloadURL }.first ?? raw.downloadURL
                        let preferredDownloadURL = preferredDownloadString.flatMap { URL(string: $0) }

                        return AltApp(
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
                            downloadURL: preferredDownloadURL,
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

        // dedupe by bundleIdentifier (keep first occurrence)
        var seen: Set<String> = []
        let deduped = combinedApps.filter { app in
            if seen.contains(app.bundleIdentifier) { return false }
            seen.insert(app.bundleIdentifier)
            return true
        }

        await MainActor.run {
            self.apps = deduped
        }

        // compute cachedApps off-main
        Task.detached { [deduped] in
            let cached = deduped.map { CachedApp(app: $0) }
            await MainActor.run {
                self.cachedApps = cached
            }
        }

        if !errors.isEmpty {
            await MainActor.run {
                self.errorMessage = errors.joined(separator: "\n")
            }
        }
    }

    func refresh() {
        Task { await loadAllSources() }
    }

    // NEW method to update source URLs and reload only if changed
    func updateSourceURLs(_ newURLs: [URL]) {
        if Set(sourceURLs) != Set(newURLs) {
            self.sourceURLs = newURLs
            Task {
                await loadAllSources()
            }
        }
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
// MARK: - AppsView (updated to use cached + vm search/sort)
public struct AppsView: View {
    @EnvironmentObject var sourcesViewModel: SourcesViewModel
    @StateObject private var vm: RepoViewModel
    @FocusState private var searchFieldFocused: Bool
    @State private var selectedApp: AltApp? = nil
    @State private var expandedRepos: Set<String> = []
    
    public init() {
        _vm = StateObject(wrappedValue: RepoViewModel(sourceURLs: []))
    }
    // MARK: - Helpers using cached data (fast)
    private var cachedList: [CachedApp] { vm.displayedCachedApps }
    private var groupedCached: [String: [CachedApp]] {
        Dictionary(grouping: cachedList, by: { $0.repoName })
    }
    private var orderedRepoKeys: [String] {
        let keys = Array(groupedCached.keys)
        if vm.selectedSort == .repoAZ {
            return keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } else {
            var order: [String] = []
            for c in cachedList {
                let key = c.repoName
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
                    TextField("Search apps, developer or bundle ID", text: $vm.searchQuery)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($searchFieldFocused)
                        .submitLabel(.search)
                    if !vm.searchQuery.isEmpty {
                        Button(action: { vm.searchQuery = "" }) {
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
                Picker(selection: $vm.selectedSort, label: Label("Sort", systemImage: "arrow.up.arrow.down")) {
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
                        Text("\(groupedCached[repoKey]?.count ?? 0) app\( (groupedCached[repoKey]?.count ?? 0) == 1 ? "" : "s")")
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
        Section {
            if expandedRepos.contains(repoKey) {
                ForEach(groupedCached[repoKey] ?? []) { cached in
                    Button { selectedApp = cached.app } label: { AppRowView(app: cached.app) }
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
        if vm.selectedSort == .repoAZ {
            List {
                ForEach(orderedRepoKeys, id: \.self) { repoKey in
                    repoSection(repoKey)
                }
            }
            .listStyle(PlainListStyle())
            .refreshable { vm.refresh() }
        } else {
            List {
                ForEach(cachedList) { cached in
                    Button { selectedApp = cached.app } label: { AppRowView(app: cached.app) }
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
            }
        }
        .onAppear {
            // Update VM with current sources
            let urls = sourcesViewModel.getSourcesURLs()
            vm.updateSourceURLs(urls)
        }
        .onChange(of: sourcesViewModel.sources) { _ in
            // Refresh when sources change
            let urls = sourcesViewModel.getSourcesURLs()
            vm.updateSourceURLs(urls)
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
                    if let cached = ImageCache.shared.get(for: iconURL) {
                        cached
                            .resizable()
                            .scaledToFill()
                            .frame(width: iconSize.width, height: iconSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
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
                                    .onAppear {
                                        if let uiImage = image.asUIImage {
                                            ImageCache.shared.set(uiImage, for: iconURL)
                                        }
                                    }
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
                    }
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
