import Foundation

class CertChecker {
    static let baseURL = URL(string: "https://check-p12.applep12.com/")!
    static let logFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("checkCert_logs.txt")
    
    // MARK: - Logging Utility
    static func log(_ message: String, includeTimestamp: Bool = true) {
        let timestamp = includeTimestamp ? "\(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)) - " : ""
        let logMessage = timestamp + message + "\n"
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                fileHandle.seekToEndOfFile()
                fileHandle.write(logMessage.data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try logMessage.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to write log: \(error)")
        }
    }
    
    // MARK: - Token Fetching
    static func getToken() async throws -> String {
        log("=== Starting getToken() ===")
        log("Requesting URL: \(baseURL.absoluteString)")
        
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL)
            
            if let httpResponse = response as? HTTPURLResponse {
                log("HTTP Status Code: \(httpResponse.statusCode)")
                log("HTTP Headers: \(httpResponse.allHeaderFields)")
            }
            
            let html = String(data: data, encoding: .utf8) ?? ""
            log("Response HTML length: \(html.count) characters")
            log("First 500 chars of HTML: \(html.prefix(500))")
            
            let pattern = "(?i)<input\\s+name=\"__RequestVerificationToken\"\\s+type=\"hidden\"\\s+value=\"([^\"]+)\""
            log("Searching for token with pattern: \(pattern)")
            
            let regex = try? NSRegularExpression(pattern: pattern)
            if let regex = regex {
                let matches = regex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
                log("Found \(matches.count) matches for token pattern")
                
                if let match = matches.first {
                    if let range = Range(match.range(at: 1), in: html) {
                        let token = String(html[range])
                        log("Successfully extracted token: \(token)")
                        log("=== Finished getToken() Successfully ===")
                        return token
                    }
                }
            } else {
                log("Failed to create regex pattern")
            }
            
            log("ERROR: Token not found in HTML")
            log("HTML sample around token area (chars 0-2000): \(html.prefix(2000))")
            
        } catch {
            log("ERROR in getToken(): \(error.localizedDescription)")
            log("Error details: \(error)")
        }
        
        log("=== getToken() Failed ===")
        throw NSError(domain: "Token not found", code: 0)
    }
    
    // MARK: - Submit Certificate
    static func submit(token: String, p12Data: Data, p12Filename: String, mpData: Data, mpFilename: String, password: String) async throws -> String {
        log("=== Starting submit() ===")
        log("Token received: \(token)")
        log("P12 Filename: \(p12Filename), Size: \(p12Data.count) bytes")
        log("MobileProvision Filename: \(mpFilename), Size: \(mpData.count) bytes")
        log("Password length: \(password.count) characters")
        log("Password (masked): \(String(repeating: "*", count: password.count))")
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://check-p12.applep12.com", forHTTPHeaderField: "Origin")
        
        log("Request Headers:")
        log("  Content-Type: multipart/form-data; boundary=\(boundary)")
        log("  User-Agent: \(request.value(forHTTPHeaderField: "User-Agent") ?? "nil")")
        log("  Referer: \(request.value(forHTTPHeaderField: "Referer") ?? "nil")")
        log("  Origin: \(request.value(forHTTPHeaderField: "Origin") ?? "nil")")
        
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
        
        log("Building multipart form data:")
        addPart(name: "P12File", filename: p12Filename, contentType: "application/x-pkcs12", data: p12Data)
        log("  Added P12File part: \(p12Filename)")
        
        addPart(name: "P12PassWord", value: password)
        log("  Added P12PassWord part")
        
        addPart(name: "MobileProvisionFile", filename: mpFilename, contentType: "application/octet-stream", data: mpData)
        log("  Added MobileProvisionFile part: \(mpFilename)")
        
        addPart(name: "__RequestVerificationToken", value: token)
        log("  Added __RequestVerificationToken part")
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        log("Total request body size: \(body.count) bytes")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                log("Submission Response:")
                log("  HTTP Status Code: \(httpResponse.statusCode)")
                log("  HTTP Headers: \(httpResponse.allHeaderFields)")
                
                if httpResponse.statusCode != 200 {
                    log("WARNING: Non-200 status code received")
                }
            }
            
            let html = String(data: data, encoding: .utf8) ?? ""
            log("Response HTML length: \(html.count) characters")
            
            // Log first 2000 chars and last 1000 chars
            if html.count > 0 {
                let firstPart = html.prefix(2000)
                let lastPart = html.suffix(1000)
                log("First 2000 chars of response: \(firstPart)")
                log("Last 1000 chars of response: \(lastPart)")
            } else {
                log("WARNING: Empty response received")
            }
            
            // Check for common error indicators
            if html.lowercased().contains("error") {
                log("ERROR INDICATOR: HTML contains 'error'")
            }
            if html.lowercased().contains("invalid") {
                log("ERROR INDICATOR: HTML contains 'invalid'")
            }
            if html.lowercased().contains("incorrect") {
                log("ERROR INDICATOR: HTML contains 'incorrect'")
            }
            
            log("=== Finished submit() Successfully ===")
            return html
            
        } catch {
            log("ERROR in submit(): \(error.localizedDescription)")
            log("Error details: \(error)")
            log("=== submit() Failed ===")
            throw error
        }
    }
    
    // MARK: - HTML Parsing
    static func parseHTML(html: String) -> [String: Any] {
        log("=== Starting parseHTML() ===")
        log("Input HTML length: \(html.count) characters")
        
        var data: [String: Any] = [
            "certificate": [String: String](),
            "mobileprovision": [String: String](),
            "binding_certificate_1": [String: String](),
            "permissions": [String: String]()
        ]
        
        // First, try to find alert div
        let divPattern = "(?i)<div\\s+class=\"[^\"]*alert[^\"]*\"[^>]*>(.*?)</div>"
        log("Searching for alert div with pattern: \(divPattern)")
        
        let divRegex = try? NSRegularExpression(pattern: divPattern, options: .dotMatchesLineSeparators)
        
        if let divRegex = divRegex {
            let matches = divRegex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
            log("Found \(matches.count) alert div matches")
            
            if let match = matches.first, let range = Range(match.range(at: 1), in: html) {
                var divContent = String(html[range])
                log("Alert div content length: \(divContent.count) characters")
                log("Original alert div content: \(divContent)")
                
                // Clean up the content
                divContent = divContent.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
                divContent = divContent.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
                
                let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
                divContent = tagRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent
                
                let emojiRegex = try? NSRegularExpression(pattern: "[🟢🔴]", options: [])
                divContent = emojiRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent
                
                log("Cleaned alert div content: \(divContent)")
                
                var lines = divContent.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                log("Found \(lines.count) lines after cleaning")
                log("Lines: \(lines)")
                
                func findIndex(prefixes: [String], start: Int = 0) -> Int? {
                    for i in start..<lines.count {
                        for p in prefixes {
                            if lines[i].lowercased().hasPrefix(p.lowercased()) {
                                log("Found '\(p)' at line \(i): '\(lines[i])'")
                                return i
                            }
                        }
                    }
                    log("Could not find any of \(prefixes) in lines")
                    return nil
                }
                
                let certIdx = findIndex(prefixes: ["CertName:", "CertName："])
                let mpIdx = findIndex(prefixes: ["MP Name:", "MP Name："])
                let bindingIdx = findIndex(prefixes: ["Binding Certificates:", "Binding Certificates："], start: mpIdx ?? 0)
                let certMatchingIdx = findIndex(prefixes: ["Certificate Matching Status:", "Certificate Matching Status："], start: bindingIdx ?? 0)
                
                log("Index positions:")
                log("  certIdx: \(certIdx?.description ?? "nil")")
                log("  mpIdx: \(mpIdx?.description ?? "nil")")
                log("  bindingIdx: \(bindingIdx?.description ?? "nil")")
                log("  certMatchingIdx: \(certMatchingIdx?.description ?? "nil")")
                
                func splitKV(line: String) -> (String, String) {
                    let separators = [":", "："]
                    for sep in separators {
                        if let range = line.range(of: sep) {
                            let k = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                            let v = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                            log("Split line '\(line)' -> key: '\(k)', value: '\(v)'")
                            return (k, v)
                        }
                    }
                    log("Could not split line: '\(line)'")
                    return (line.trimmingCharacters(in: .whitespaces), "")
                }
                
                // Parse Certificate Info
                if let certIdx = certIdx {
                    let end = mpIdx ?? (bindingIdx ?? lines.count)
                    log("Parsing certificate from line \(certIdx) to \(end)")
                    var cert = data["certificate"] as! [String: String]
                    
                    for i in certIdx..<end {
                        let (k, v) = splitKV(line: lines[i])
                        let lk = k.lowercased()
                        
                        if lk.hasPrefix("certname") {
                            cert["name"] = v
                            log("Set certificate name: \(v)")
                        } else if lk.hasPrefix("effective date") {
                            cert["effective"] = v
                            log("Set effective date: \(v)")
                        } else if lk.hasPrefix("expiration date") {
                            cert["expiration"] = v
                            log("Set expiration date: \(v)")
                        } else if lk.hasPrefix("issuer") {
                            cert["issuer"] = v
                            log("Set issuer: \(v)")
                        } else if lk.hasPrefix("country") {
                            cert["country"] = v
                            log("Set country: \(v)")
                        } else if lk.hasPrefix("organization") {
                            cert["organization"] = v
                            log("Set organization: \(v)")
                        } else if lk.hasPrefix("certificate number (hex)") {
                            cert["number_hex"] = v
                            log("Set certificate number (hex): \(v)")
                        } else if lk.hasPrefix("certificate number (decimal)") {
                            cert["number_decimal"] = v
                            log("Set certificate number (decimal): \(v)")
                        } else if lk.hasPrefix("certificate status") {
                            cert["status"] = v
                            log("Set certificate status: \(v)")
                        }
                    }
                    data["certificate"] = cert
                    log("Final certificate data: \(cert)")
                } else {
                    log("WARNING: No certificate info found")
                }
                
                // Parse MobileProvision Info
                if let mpIdx = mpIdx {
                    let end = bindingIdx ?? (certMatchingIdx ?? lines.count)
                    log("Parsing mobileprovision from line \(mpIdx) to \(end)")
                    var mp = data["mobileprovision"] as! [String: String]
                    
                    for i in mpIdx..<end {
                        let (k, v) = splitKV(line: lines[i])
                        let lk = k.lowercased()
                        
                        if lk.hasPrefix("mp name") {
                            mp["name"] = v
                            log("Set mobileprovision name: \(v)")
                        } else if lk.hasPrefix("app id") {
                            mp["app_id"] = v
                            log("Set app id: \(v)")
                        } else if lk.hasPrefix("identifier") {
                            mp["identifier"] = v
                            log("Set identifier: \(v)")
                        } else if lk.hasPrefix("platform") {
                            mp["platform"] = v
                            log("Set platform: \(v)")
                        } else if lk.hasPrefix("effective date") {
                            if mp["effective"] == nil {
                                mp["effective"] = v
                                log("Set mobileprovision effective date: \(v)")
                            }
                        } else if lk.hasPrefix("expiration date") {
                            if mp["expiration"] == nil {
                                mp["expiration"] = v
                                log("Set mobileprovision expiration date: \(v)")
                            }
                        }
                    }
                    data["mobileprovision"] = mp
                    log("Final mobileprovision data: \(mp)")
                } else {
                    log("WARNING: No mobileprovision info found")
                }
                
                // Parse Binding Certificate
                if let bindingIdx = bindingIdx {
                    let cert1Idx = findIndex(prefixes: ["Certificate 1:", "Certificate 1：", "Certificate 1"], start: bindingIdx)
                    if let cert1Idx = cert1Idx {
                        let cert2Idx = findIndex(prefixes: ["Certificate 2:", "Certificate 2：", "Certificate 2"], start: cert1Idx + 1)
                        let end = cert2Idx ?? (certMatchingIdx ?? lines.count)
                        log("Parsing binding certificate from line \(cert1Idx + 1) to \(end)")
                        
                        var bc1 = data["binding_certificate_1"] as! [String: String]
                        
                        for i in (cert1Idx + 1)..<end {
                            let (k, v) = splitKV(line: lines[i])
                            let lk = k.lowercased()
                            
                            if lk.hasPrefix("certificate status") {
                                bc1["status"] = v
                                log("Set binding certificate status: \(v)")
                            } else if lk.hasPrefix("certificate number (hex)") {
                                bc1["number_hex"] = v
                                log("Set binding certificate number (hex): \(v)")
                            } else if lk.hasPrefix("certificate number (decimal)") {
                                bc1["number_decimal"] = v
                                log("Set binding certificate number (decimal): \(v)")
                            }
                        }
                        data["binding_certificate_1"] = bc1
                        log("Final binding certificate data: \(bc1)")
                    } else {
                        log("WARNING: Could not find Certificate 1 within binding certificates section")
                    }
                } else {
                    log("WARNING: No binding certificates section found")
                }
                
                // Parse Permissions
                let permKeys = [
                    "Apple Push Notification Service",
                    "HealthKit",
                    "VPN",
                    "Communication Notifications",
                    "Time-sensitive Notifications"
                ]
                log("Looking for permissions in lines")
                
                var perms = data["permissions"] as! [String: String]
                for line in lines {
                    for pk in permKeys {
                        if line.hasPrefix(pk) {
                            let (_, v) = splitKV(line: line)
                            perms[pk] = v
                            log("Found permission '\(pk)': \(v)")
                        }
                    }
                }
                data["permissions"] = perms
                
                // Parse Certificate Matching Status
                if let certMatchingIdx = certMatchingIdx {
                    let (_, v) = splitKV(line: lines[certMatchingIdx])
                    data["certificate_matching_status"] = v
                    log("Certificate matching status: \(v)")
                } else {
                    log("WARNING: No certificate matching status found")
                }
                
                log("Final parsed data: \(data)")
                log("=== Finished parseHTML() Successfully ===")
                return data
            } else {
                log("WARNING: No alert div found in HTML")
            }
        } else {
            log("ERROR: Could not create div regex")
        }
        
        log("ERROR: Could not parse certificate info from HTML")
        log("HTML sample (chars 0-3000): \(html.prefix(3000))")
        log("=== parseHTML() Failed ===")
        
        return ["error": "No certificate info found in response", "raw_html_preview": String(html.prefix(1000))]
    }
    
    // MARK: - Main Check Function
    static func checkCert(mobileProvision: Data, mobileProvisionFilename: String = "example.mobileprovision",
                          p12: Data, p12Filename: String = "example.p12",
                          password: String) async throws -> [String: Any] {
        log("\n\n" + String(repeating: "=", count: 80))
        log("=== STARTING NEW CERTIFICATE CHECK ===")
        log("Timestamp: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .full))")
        log(String(repeating: "=", count: 80))
        
        do {
            // Get token
            log("Step 1: Getting token...")
            let token = try await getToken()
            
            // Submit certificate
            log("\nStep 2: Submitting certificate for checking...")
            let html = try await submit(token: token, 
                                        p12Data: p12, 
                                        p12Filename: p12Filename, 
                                        mpData: mobileProvision, 
                                        mpFilename: mobileProvisionFilename, 
                                        password: password)
            
            // Parse HTML response
            log("\nStep 3: Parsing HTML response...")
            let parsedData = parseHTML(html: html)
            
            // Extract status for logging
            let certStatus = (parsedData["certificate"] as? [String: String])?["status"] ?? "Not found"
            let matchingStatus = parsedData["certificate_matching_status"] as? String ?? "Not found"
            
            log("\n=== CHECK SUMMARY ===")
            log("Certificate Status: \(certStatus)")
            log("Certificate Matching Status: \(matchingStatus)")
            log("Final Status: \(certStatus != "Not found" ? certStatus : matchingStatus)")
            log("=== CERTIFICATE CHECK COMPLETED ===\n")
            
            return parsedData
            
        } catch {
            log("\n=== CERTIFICATE CHECK FAILED ===")
            log("Error: \(error.localizedDescription)")
            log("Error details: \(error)")
            log("=== END WITH ERROR ===\n")
            throw error
        }
    }
    
    // MARK: - Utility to View Logs
    static func getLogContent() -> String {
        do {
            return try String(contentsOf: logFileURL, encoding: .utf8)
        } catch {
            return "No logs available or error reading: \(error)"
        }
    }
    
    static func clearLogs() {
        do {
            try "".write(to: logFileURL, atomically: true, encoding: .utf8)
            log("=== Logs cleared ===", includeTimestamp: false)
        } catch {
            log("Failed to clear logs: \(error)", includeTimestamp: false)
        }
    }
}