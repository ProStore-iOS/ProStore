import Foundation
import CryptoKit

class CertChecker {
    static let baseURL = URL(string: "https://certChecker.novadev.vip/checkCert")!

    // MARK: - Cache types
    struct CacheEntry: Codable {
        var p12: [String: AnyCodable]
        var mobileprovision: [String: AnyCodable]
        var overall_status: String
        var timestamp: Date
    }

    // Helper to encode/decode heterogeneous JSON values as Codable
    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let doubleValue = try? container.decode(Double.self) {
                value = doubleValue
            } else if let boolValue = try? container.decode(Bool.self) {
                value = boolValue
            } else if let stringValue = try? container.decode(String.self) {
                value = stringValue
            } else if let arrayValue = try? container.decode([AnyCodable].self) {
                value = arrayValue.map { $0.value }
            } else if let dictValue = try? container.decode([String: AnyCodable].self) {
                value = dictValue.mapValues { $0.value }
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            switch value {
            case let intValue as Int:
                try container.encode(intValue)
            case let doubleValue as Double:
                try container.encode(doubleValue)
            case let boolValue as Bool:
                try container.encode(boolValue)
            case let stringValue as String:
                try container.encode(stringValue)
            case let arrayValue as [Any]:
                let encodableArray = arrayValue.map { AnyCodable($0) }
                try container.encode(encodableArray)
            case let dictValue as [String: Any]:
                let encodableDict = dictValue.mapValues { AnyCodable($0) }
                try container.encode(encodableDict)
            default:
                let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported JSON value")
                throw EncodingError.invalidValue(value, context)
            }
        }
    }

    private static var cacheDirectory: URL {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("CertCheckerCache", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    private static func cacheFileURL(forKey key: String) -> URL {
        return cacheDirectory.appendingPathComponent("\(key).json")
    }

    private static func makeCacheKey(p12Data: Data, mpData: Data, password: String) -> String {
        var ctx = Data()
        ctx.append(p12Data)
        ctx.append(mpData)
        if let pw = password.data(using: .utf8) {
            ctx.append(pw)
        }
        let hash = SHA256.hash(data: ctx)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func saveCache(key: String, parsed: [String: Any]) {
        // Convert parsed dictionary into CacheEntry with AnyCodable wrappers
        let p12 = (parsed["p12"] as? [String: Any])?.mapValues { AnyCodable($0) } ?? [:]
        let mobileprovision = (parsed["mobileprovision"] as? [String: Any])?.mapValues { AnyCodable($0) } ?? [:]
        let overall = (parsed["overall_status"] as? String) ?? "Unknown"

        let entry = CacheEntry(
            p12: p12,
            mobileprovision: mobileprovision,
            overall_status: overall,
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entry)
            try data.write(to: cacheFileURL(forKey: key), options: [.atomic])
        } catch {
            // silently ignore cache write errors
        }
    }

    private static func loadCacheEntry(forKey key: String) -> [String: Any]? {
        let url = cacheFileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let entry = try decoder.decode(CacheEntry.self, from: data)
            // convert back AnyCodable to Any
            var result: [String: Any] = [:]
            result["p12"] = entry.p12.mapValues { $0.value }
            result["mobileprovision"] = entry.mobileprovision.mapValues { $0.value }
            result["overall_status"] = entry.overall_status
            result["cached_timestamp"] = ISO8601DateFormatter().string(from: entry.timestamp)
            return result
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Public cache API
    static func cachedResult(p12Data: Data, mpData: Data, password: String) -> [String: Any]? {
        let key = makeCacheKey(p12Data: p12Data, mpData: mpData, password: password)
        return loadCacheEntry(forKey: key)
    }

    // MARK: - Main Check Function
    static func checkCert(mobileProvision: Data,
                          mobileProvisionFilename: String = "example.mobileprovision",
                          p12: Data,
                          p12Filename: String = "example.p12",
                          password: String) async throws -> [String: Any] {

        let key = makeCacheKey(p12Data: p12, mpData: mobileProvision, password: password)

        // Prepare multipart form data request to your API
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (iOS)", forHTTPHeaderField: "User-Agent")

        var body = Data()

        func addPart(name: String, filename: String? = nil, contentType: String? = nil, data: Data? = nil, value: String? = nil) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            if let filename = filename {
                body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                if let contentType = contentType {
                    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
                } else {
                    body.append("\r\n".data(using: .utf8)!)
                }
                if let data = data {
                    body.append(data)
                }
            } else {
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                if let value = value {
                    body.append(value.data(using: .utf8)!)
                }
            }
            body.append("\r\n".data(using: .utf8)!)
        }

        addPart(name: "p12", filename: p12Filename, contentType: "application/x-pkcs12", data: p12)
        addPart(name: "mobileprovision", filename: mobileProvisionFilename, contentType: "application/octet-stream", data: mobileProvision)
        addPart(name: "password", value: password)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw NSError(domain: "CertChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        // Parse JSON response
        let json = try JSONSerialization.jsonObject(with: data, options: [])

        guard let dict = json as? [String: Any] else {
            throw NSError(domain: "CertChecker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON structure"])
        }

        // Save cache async
        DispatchQueue.global(qos: .background).async {
            saveCache(key: key, parsed: dict)
        }

        return dict
    }
}

fileprivate extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
