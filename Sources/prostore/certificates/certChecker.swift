import Foundation
import CryptoKit

class CertChecker {
    static let baseURL = URL(string: "https://check-p12.applep12.com/")!

    // MARK: - Cache types
    struct CacheEntry: Codable {
        var certificate: [String: String]
        var mobileprovision: [String: String]
        var binding_certificate_1: [String: String]
        var permissions: [String: String]
        var overall_status: String
        var timestamp: Date
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
        // Convert parsed dictionary into CacheEntry (provide sensible defaults)
        let certificate = parsed["certificate"] as? [String: String] ?? [:]
        let mobileprovision = parsed["mobileprovision"] as? [String: String] ?? [:]
        let binding = parsed["binding_certificate_1"] as? [String: String] ?? [:]
        let permissions = parsed["permissions"] as? [String: String] ?? [:]
        let overall = (parsed["overall_status"] as? String) ?? (parsed["overallStatus"] as? String) ?? "Unknown"

        let entry = CacheEntry(
            certificate: certificate,
            mobileprovision: mobileprovision,
            binding_certificate_1: binding,
            permissions: permissions,
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
            // print("CertChecker: failed to write cache: \(error)")
        }
    }

    private static func loadCacheEntry(forKey key: String) -> CacheEntry? {
        let url = cacheFileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let entry = try decoder.decode(CacheEntry.self, from: data)
            return entry
        } catch {
            // corrupted cache — remove file
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func cacheEntryToDict(_ entry: CacheEntry) -> [String: Any] {
        return [
            "certificate": entry.certificate,
            "mobileprovision": entry.mobileprovision,
            "binding_certificate_1": entry.binding_certificate_1,
            "permissions": entry.permissions,
            "overall_status": entry.overall_status,
            "cached_timestamp": ISO8601DateFormatter().string(from: entry.timestamp)
        ]
    }

    // MARK: - Token Fetching
    static func getToken() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: baseURL)

        let html = String(data: data, encoding: .utf8) ?? ""

        let pattern = "(?i)<input\\s+name=\"__RequestVerificationToken\"\\s+type=\"hidden\"\\s+value=\"([^\"]+)\""
        let regex = try? NSRegularExpression(pattern: pattern)

        if let regex = regex {
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))

            if let match = matches.first,
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }

        throw NSError(domain: "Token not found", code: 0)
    }

    // MARK: - Submit Certificate
    static func submit(token: String,
                       p12Data: Data,
                       p12Filename: String,
                       mpData: Data,
                       mpFilename: String,
                       password: String) async throws -> String {

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://check-p12.applep12.com", forHTTPHeaderField: "Origin")

        var body = Data()

        func addPart(name: String,
                     value: String? = nil,
                     filename: String? = nil,
                     contentType: String? = nil,
                     data: Data? = nil) {

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            if let filename = filename {
                body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
                if let contentType = contentType {
                    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
                }
            } else {
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            }

            if let value = value {
                body.append(value.data(using: .utf8)!)
            } else if let data = data {
                body.append(data)
            }

            body.append("\r\n".data(using: .utf8)!)
        }

        addPart(name: "P12File", filename: p12Filename, contentType: "application/x-pkcs12", data: p12Data)
        addPart(name: "P12PassWord", value: password)
        addPart(name: "MobileProvisionFile", filename: mpFilename, contentType: "application/octet-stream", data: mpData)
        addPart(name: "__RequestVerificationToken", value: token)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - HTML Parsing (unchanged)
    static func parseHTML(html: String) -> [String: Any] {
        // (copy your existing parseHTML implementation here unchanged)
        // For brevity in this snippet we call your original parseHTML implementation.
        // Replace the following line with your full parseHTML method body.
        // ---------------------------
        // (Begin of original method)
        var data: [String: Any] = [
            "certificate": [String: String](),
            "mobileprovision": [String: String](),
            "binding_certificate_1": [String: String](),
            "permissions": [String: String]()
        ]

        // Look for main alert div
        let divPattern = "(?i)<div[^>]*class=\"[^\"]*alert[^\"]*\"[^>]*>(.*?)</div>"
        let divRegex = try? NSRegularExpression(pattern: divPattern, options: .dotMatchesLineSeparators)

        if let divRegex = divRegex {
            let matches = divRegex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))

            if let match = matches.first,
               let range = Range(match.range(at: 1), in: html) {

                var divContent = String(html[range])
                divContent = divContent.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
                divContent = divContent.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
                divContent = divContent.replacingOccurrences(of: "&emsp;", with: "    ", options: .caseInsensitive)

                let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>")
                divContent = tagRegex?.stringByReplacingMatches(in: divContent,
                                                                range: NSRange(0..<divContent.utf16.count),
                                                                withTemplate: "") ?? divContent

                divContent = divContent.replacingOccurrences(of: "🟢", with: "")
                divContent = divContent.replacingOccurrences(of: "🔴", with: "")

                let rawLines = divContent.components(separatedBy: .newlines)
                let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }

                enum Section {
                    case certificate, mobileprovision, bindingCertificates, permissions, unknown
                }

                var currentSection: Section = .unknown
                var bindingCertIndex = 0

                for line in lines {
                    if line.contains("-----------------------------------") {
                        currentSection = .mobileprovision
                        continue
                    } else if line.contains("Binding Certificates:") {
                        currentSection = .bindingCertificates
                        continue
                    } else if line.contains("Permission Status:") {
                        currentSection = .permissions
                        continue
                    }

                    let separators = [": ", "："]
                    var key: String?
                    var value: String?

                    for sep in separators {
                        if let range = line.range(of: sep) {
                            key = String(line[..<range.lowerBound])
                            value = String(line[range.upperBound...])
                            break
                        }
                    }

                    guard let key = key?.trimmingCharacters(in: .whitespaces),
                          let value = value?.trimmingCharacters(in: .whitespaces) else { continue }

                    switch currentSection {
                    case .certificate, .unknown:
                        var cert = data["certificate"] as! [String: String]
                        let lk = key.lowercased()

                        if lk.contains("certname") {
                            cert["name"] = value
                        } else if lk.contains("effective date") && !lk.contains("cert") {
                            cert["effective"] = value
                        } else if lk.contains("expiration date") && !lk.contains("cert") {
                            cert["expiration"] = value
                        } else if lk.contains("issuer") {
                            cert["issuer"] = value
                        } else if lk.contains("country") {
                            cert["country"] = value
                        } else if lk.contains("organization") {
                            cert["organization"] = value
                        } else if lk.contains("certificate number (hex)") {
                            cert["number_hex"] = value
                        } else if lk.contains("certificate number (decimal)") {
                            cert["number_decimal"] = value
                        } else if lk.contains("certificate status") && !lk.contains("binding") {
                            cert["status"] = value
                        }

                        data["certificate"] = cert

                    case .mobileprovision:
                        var mp = data["mobileprovision"] as! [String: String]
                        let lk = key.lowercased()

                        if lk.contains("mp name") {
                            mp["name"] = value
                        } else if lk.contains("app id") {
                            mp["app_id"] = value
                        } else if lk.contains("identifier") {
                            mp["identifier"] = value
                        } else if lk.contains("platform") {
                            mp["platform"] = value
                        } else if lk.contains("effective date") {
                            mp["effective"] = value
                        } else if lk.contains("expiration date") {
                            mp["expiration"] = value
                        }

                        data["mobileprovision"] = mp

                    case .bindingCertificates:
                        if key.contains("Certificate 1") {
                            bindingCertIndex = 1
                        } else if key.contains("Certificate 2") || key.contains("Certificate 3") {
                            bindingCertIndex = 0
                            continue
                        }

                        if bindingCertIndex == 1 {
                            var bc1 = data["binding_certificate_1"] as! [String: String]
                            let lk = key.lowercased()

                            if lk.contains("certificate status") {
                                bc1["status"] = value
                            } else if lk.contains("certificate number (hex)") {
                                bc1["number_hex"] = value
                            } else if lk.contains("certificate number (decimal)") {
                                bc1["number_decimal"] = value
                            }
                            data["binding_certificate_1"] = bc1
                        }

                    case .permissions:
                        var perms = data["permissions"] as! [String: String]
                        let permKeys = [
                            "Apple Push Notification Service",
                            "HealthKit",
                            "VPN",
                            "Communication Notifications",
                            "Time-sensitive Notifications"
                        ]

                        for permKey in permKeys {
                            if key.contains(permKey) {
                                perms[permKey] = value
                            }
                        }

                        data["permissions"] = perms

                        if key.contains("Certificate Matching Status") {
                            data["certificate_matching_status"] = value
                        }
                    }
                }

                let cert = data["certificate"] as! [String: String]
                let certStatus = cert["status"] ?? ""
                let matchingStatus = data["certificate_matching_status"] as? String ?? ""

                let overallStatus: String
                if certStatus.lowercased().contains("good") &&
                   matchingStatus.lowercased().contains("match") {
                    overallStatus = "Valid"
                } else if certStatus.lowercased().contains("good") ||
                          matchingStatus.lowercased().contains("match") {
                    overallStatus = "Partially Valid"
                } else {
                    overallStatus = "Invalid"
                }

                data["overall_status"] = overallStatus
                return data
            }
        }

        // Fallback
        var fallbackStatus = "Unknown"
        if html.contains("🟢Good") && html.contains("🟢Match") {
            fallbackStatus = "Valid"
        } else if html.contains("🔴") {
            fallbackStatus = "Invalid"
        }

        return ["overall_status": fallbackStatus]
        // (End of original method)
        // ---------------------------
    }

    // MARK: - Public cache API

    /// Synchronously returns the cached parsed dictionary (if any) for the supplied inputs.
    /// Use this to show a cached result immediately while you await a fresh result.
    static func cachedResult(p12Data: Data, mpData: Data, password: String) -> [String: Any]? {
        let key = makeCacheKey(p12Data: p12Data, mpData: mpData, password: password)
        guard let entry = loadCacheEntry(forKey: key) else { return nil }
        return cacheEntryToDict(entry)
    }

    // MARK: - Main Check Function (network + cache update)
    static func checkCert(mobileProvision: Data,
                          mobileProvisionFilename: String = "example.mobileprovision",
                          p12: Data,
                          p12Filename: String = "example.p12",
                          password: String) async throws -> [String: Any] {

        // compute cache key so we can update cache later
        let key = makeCacheKey(p12Data: p12, mpData: mobileProvision, password: password)

        // perform network fetch as before
        let token = try await getToken()

        let html = try await submit(
            token: token,
            p12Data: p12,
            p12Filename: p12Filename,
            mpData: mobileProvision,
            mpFilename: mobileProvisionFilename,
            password: password
        )

        let parsed = parseHTML(html: html)

        // update cache (fire-and-forget style)
        DispatchQueue.global(qos: .background).async {
            saveCache(key: key, parsed: parsed)
        }

        return parsed
    }
}
