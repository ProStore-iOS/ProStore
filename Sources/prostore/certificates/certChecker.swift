import Foundation

class CertChecker {
    static let baseURL = URL(string: "https://check-p12.applep12.com/")!

    static func getToken() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: baseURL)
        let html = String(data: data, encoding: .utf8) ?? ""
        let pattern = "(?i)<input\\s+name=\"__RequestVerificationToken\"\\s+type=\"hidden\"\\s+value=\"([^\"]+)\""
        let regex = try? NSRegularExpression(pattern: pattern)
        if let match = regex?.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        throw NSError(domain: "Token not found", code: 0)
    }

    static func submit(token: String, p12Data: Data, p12Filename: String, mpData: Data, mpFilename: String, password: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://check-p12.applep12.com", forHTTPHeaderField: "Origin")

        var body = Data()

        func addPart(name: String, value: String? = nil, filename: String? = nil, contentType: String? = nil, data: Data? = nil) {
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

    static func parseHTML(html: String) -> [String: Any] {
        let divPattern = "(?i)<div\\s+class=\"[^\"]*alert[^\"]*\"[^>]*>(.*?)</div>"
        let divRegex = try? NSRegularExpression(pattern: divPattern, options: .dotMatchesLineSeparators)
        guard let match = divRegex?.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
              let range = Range(match.range(at: 1), in: html) else {
            return ["error": "No certificate info found in response"]
        }

        var divContent = String(html[range])
        divContent = divContent.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        divContent = divContent.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
        divContent = tagRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent

        var lines = divContent.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let emojiRegex = try? NSRegularExpression(pattern: "[🟢🔴]", options: [])
        for i in 0..<lines.count {
            lines[i] = emojiRegex?.stringByReplacingMatches(in: lines[i], range: NSRange(0..<lines[i].utf16.count), withTemplate: "") ?? lines[i]
        }

        var data: [String: Any] = [
            "certificate": [String: String](),
            "mobileprovision": [String: String](),
            "binding_certificate_1": [String: String](),
            "permissions": [String: String]()
        ]

        func findIndex(prefixes: [String], start: Int = 0) -> Int? {
            for i in start..<lines.count {
                for p in prefixes {
                    if lines[i].lowercased().hasPrefix(p.lowercased()) {
                        return i
                    }
                }
            }
            return nil
        }

        let certIdx = findIndex(prefixes: ["CertName:", "CertName："])
        let mpIdx = findIndex(prefixes: ["MP Name:", "MP Name："])
        let bindingIdx = findIndex(prefixes: ["Binding Certificates:", "Binding Certificates："], start: mpIdx ?? 0)
        let certMatchingIdx = findIndex(prefixes: ["Certificate Matching Status:", "Certificate Matching Status："], start: bindingIdx ?? 0)

        func splitKV(line: String) -> (String, String) {
            let separators = [":", "："]
            for sep in separators {
                if let range = line.range(of: sep) {
                    let k = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let v = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    return (k, v)
                }
            }
            return (line.trimmingCharacters(in: .whitespaces), "")
        }

        if let certIdx = certIdx {
            let end = mpIdx ?? (bindingIdx ?? lines.count)
            for i in certIdx..<end {
                let (k, v) = splitKV(line: lines[i])
                let lk = k.lowercased()
                var cert = data["certificate"] as! [String: String]
                if lk.hasPrefix("certname") {
                    cert["name"] = v
                } else if lk.hasPrefix("effective date") {
                    cert["effective"] = v
                } else if lk.hasPrefix("expiration date") {
                    cert["expiration"] = v
                } else if lk.hasPrefix("issuer") {
                    cert["issuer"] = v
                } else if lk.hasPrefix("country") {
                    cert["country"] = v
                } else if lk.hasPrefix("organization") {
                    cert["organization"] = v
                } else if lk.hasPrefix("certificate number (hex)") {
                    cert["number_hex"] = v
                } else if lk.hasPrefix("certificate number (decimal)") {
                    cert["number_decimal"] = v
                } else if lk.hasPrefix("certificate status") {
                    cert["status"] = v
                }
                data["certificate"] = cert
            }
        }

        if let mpIdx = mpIdx {
            let end = bindingIdx ?? (certMatchingIdx ?? lines.count)
            for i in mpIdx..<end {
                let (k, v) = splitKV(line: lines[i])
                let lk = k.lowercased()
                var mp = data["mobileprovision"] as! [String: String]
                if lk.hasPrefix("mp name") {
                    mp["name"] = v
                } else if lk.hasPrefix("app id") {
                    mp["app_id"] = v
                } else if lk.hasPrefix("identifier") {
                    mp["identifier"] = v
                } else if lk.hasPrefix("platform") {
                    mp["platform"] = v
                } else if lk.hasPrefix("effective date") {
                    if mp["effective"] == nil {
                        mp["effective"] = v
                    }
                } else if lk.hasPrefix("expiration date") {
                    if mp["expiration"] == nil {
                        mp["expiration"] = v
                    }
                }
                data["mobileprovision"] = mp
            }
        }

        if let bindingIdx = bindingIdx {
            let cert1Idx = findIndex(prefixes: ["Certificate 1:", "Certificate 1：", "Certificate 1"], start: bindingIdx)
            if let cert1Idx = cert1Idx {
                let cert2Idx = findIndex(prefixes: ["Certificate 2:", "Certificate 2：", "Certificate 2"], start: cert1Idx + 1)
                let end = cert2Idx ?? (certMatchingIdx ?? lines.count)
                for i in (cert1Idx + 1)..<end {
                    let (k, v) = splitKV(line: lines[i])
                    let lk = k.lowercased()
                    var bc1 = data["binding_certificate_1"] as! [String: String]
                    if lk.hasPrefix("certificate status") {
                        bc1["status"] = v
                    } else if lk.hasPrefix("certificate number (hex)") {
                        bc1["number_hex"] = v
                    } else if lk.hasPrefix("certificate number (decimal)") {
                        bc1["number_decimal"] = v
                    }
                    data["binding_certificate_1"] = bc1
                }
            }
        }

        let permKeys = [
            "Apple Push Notification Service",
            "HealthKit",
            "VPN",
            "Communication Notifications",
            "Time-sensitive Notifications"
        ]
        for line in lines {
            for pk in permKeys {
                if line.hasPrefix(pk) {
                    let (_, v) = splitKV(line: line)
                    var perms = data["permissions"] as! [String: String]
                    perms[pk] = v
                    data["permissions"] = perms
                }
            }
        }

        if let certMatchingIdx = certMatchingIdx {
            let (_, v) = splitKV(line: lines[certMatchingIdx])
            data["certificate_matching_status"] = v
        }

        return data
    }

    static func checkCert(mobileProvision: Data, mobileProvisionFilename: String = "example.mobileprovision",
                          p12: Data, p12Filename: String = "example.p12",
                          password: String) async throws -> [String: Any] {
        let token = try await getToken()
        let html = try await submit(token: token, p12Data: p12, p12Filename: p12Filename, mpData: mobileProvision, mpFilename: mobileProvisionFilename, password: password)
        return parseHTML(html: html)
    }
}