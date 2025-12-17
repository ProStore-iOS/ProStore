import SwiftUI
import Combine

class SourcesViewModel: ObservableObject {
    @Published var sources: [Source] = []
    @Published var validationStates: [String: ValidationState] = [:] // Use String keys
    @Published var isAddingNew = false
    @Published var newSourceURL = ""
    @Published var editingSource: Source? = nil
    
    private let fileURL: URL
    
    enum ValidationState {
        case pending
        case loading
        case valid
        case invalid(Error)
        
        var description: String {
            switch self {
            case .pending: return "Not checked"
            case .loading: return "Checking..."
            case .valid: return "✓ Valid"
            case .invalid(let error): return "✗ Error: \(error.localizedDescription)"
            }
        }
        
        var icon: String {
            switch self {
            case .pending: return "questionmark.circle"
            case .loading: return "arrow.triangle.2.circlepath"
            case .valid: return "checkmark.circle.fill"
            case .invalid: return "xmark.circle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .pending: return .gray
            case .loading: return .blue
            case .valid: return .green
            case .invalid: return .red
            }
        }
    }
    
    struct Source: Identifiable, Codable, Equatable {
        let id: UUID
        var urlString: String
        
        var url: URL? {
            URL(string: urlString)
        }
        
        init(id: UUID = UUID(), urlString: String) {
            self.id = id
            self.urlString = urlString
        }
        
        static func == (lhs: Source, rhs: Source) -> Bool {
            lhs.id == rhs.id && lhs.urlString == rhs.urlString
        }
    }
    
    init() {
        let appFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = appFolder.appendingPathComponent("sources.json")
        loadSources()
    }
    
    private func loadSources() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([Source].self, from: data)
                self.sources = decoded
            } else {
                // Load default sources
                let defaultSources = [
                    "https://repository.apptesters.org/",
                    "https://wuxu1.github.io/wuxu-complete.json",
                    "https://wuxu1.github.io/wuxu-complete-plus.json",
                    "https://raw.githubusercontent.com/swaggyP36000/TrollStore-IPAs/main/apps_esign.json",
                    "https://ipa.cypwn.xyz/cypwn.json",
                    "https://quarksources.github.io/dist/quantumsource.min.json",
                    "https://bit.ly/quantumsource-plus-min",
                    "https://raw.githubusercontent.com/Neoncat-OG/TrollStore-IPAs/main/apps_esign.json"
                ]
                self.sources = defaultSources.map { Source(urlString: $0) }
                saveSources()
            }
        } catch {
            print("Failed to load sources: \(error)")
            loadDefaultSources()
        }
    }
    
    private func loadDefaultSources() {
        let defaultSources = [
            "https://repository.apptesters.org/",
            "https://wuxu1.github.io/wuxu-complete.json",
            "https://wuxu1.github.io/wuxu-complete-plus.json",
            "https://raw.githubusercontent.com/swaggyP36000/TrollStore-IPAs/main/apps_esign.json",
            "https://ipa.cypwn.xyz/cypwn.json",
            "https://quarksources.github.io/dist/quantumsource.min.json",
            "https://bit.ly/quantumsource-plus-min",
            "https://raw.githubusercontent.com/Neoncat-OG/TrollStore-IPAs/main/apps_esign.json"
        ]
        self.sources = defaultSources.map { Source(urlString: $0) }
        saveSources()
    }
    
    private func saveSources() {
        do {
            let data = try JSONEncoder().encode(sources)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save sources: \(error)")
        }
    }
    
    func addSource(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var formattedURL = trimmed
        
        // Add https:// if no scheme is present
        if !formattedURL.hasPrefix("http://") && !formattedURL.hasPrefix("https://") {
            formattedURL = "https://" + formattedURL
        }
        
        // Force HTTPS (convert http:// to https://)
        if formattedURL.hasPrefix("http://") {
            formattedURL = formattedURL.replacingOccurrences(of: "http://", with: "https://")
        }
        
        let newSource = Source(urlString: formattedURL)
        sources.append(newSource)
        saveSources()
        validateSource(newSource)
    }
    
    func deleteSource(at indexSet: IndexSet) {
        sources.remove(atOffsets: indexSet)
        saveSources()
    }
    
    func moveSource(from source: IndexSet, to destination: Int) {
        sources.move(fromOffsets: source, toOffset: destination)
        saveSources()
    }
    
    func startEditing(_ source: Source) {
        editingSource = source
        newSourceURL = source.urlString
    }
    
    func updateSource(source: Source, newURLString: String) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        
        var formattedURL = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Add https:// if no scheme is present
        if !formattedURL.hasPrefix("http://") && !formattedURL.hasPrefix("https://") {
            formattedURL = "https://" + formattedURL
        }
        
        // Force HTTPS
        if formattedURL.hasPrefix("http://") {
            formattedURL = formattedURL.replacingOccurrences(of: "http://", with: "https://")
        }
        
        sources[index].urlString = formattedURL
        saveSources()
        validateSource(sources[index])
        editingSource = nil
        newSourceURL = ""
    }
    
    func validateSource(_ source: Source) {
        // Always set to loading first
        validationStates[source.urlString] = .loading
        
        guard let url = source.url else {
            validationStates[source.urlString] = .invalid(NSError(domain: "Invalid URL", code: 0, userInfo: nil))
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("AppTestersListView/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.validationStates[source.urlString] = .invalid(error)
                } else if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    let error = NSError(domain: "HTTP Error", code: httpResponse.statusCode, userInfo: nil)
                    self?.validationStates[source.urlString] = .invalid(error)
                } else {
                    self?.validationStates[source.urlString] = .valid
                }
            }
        }.resume()
    }
    
    func validateAllSources() {
        for source in sources {
            validateSource(source)
        }
    }
    
    func getSourcesURLs() -> [URL] {
        sources.compactMap { $0.url }
    }
}