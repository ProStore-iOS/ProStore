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
    
    // First, try to find alert div with more flexible pattern
    let divPattern = "(?i)<div[^>]*class=\"[^\"]*alert[^\"]*\"[^>]*>(.*?)</div>"
    log("Searching for alert div with pattern: \(divPattern)")
    
    let divRegex = try? NSRegularExpression(pattern: divPattern, options: .dotMatchesLineSeparators)
    
    if let divRegex = divRegex {
        let matches = divRegex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
        log("Found \(matches.count) alert div matches")
        
        if let match = matches.first, let range = Range(match.range(at: 1), in: html) {
            var divContent = String(html[range])
            log("Alert div content length: \(divContent.count) characters")
            
            // Clean up the content
            divContent = divContent.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            divContent = divContent.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            divContent = divContent.replacingOccurrences(of: "&emsp;", with: "    ", options: .caseInsensitive)
            
            // Remove HTML tags
            let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
            divContent = tagRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent
            
            // Remove emojis and special characters but keep text
            let emojiRegex = try? NSRegularExpression(pattern: "[\\🟢🔴]", options: [])
            divContent = emojiRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent
            
            // Clean up multiple spaces and newlines
            divContent = divContent.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            divContent = divContent.replacingOccurrences(of: "\\n\\s*\\n", with: "\n", options: .regularExpression)
            
            log("Cleaned alert div content: \(divContent)")
            
            var lines = divContent.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            log("Found \(lines.count) lines after cleaning")
            
            // SIMPLIFIED PARSING APPROACH
            // Instead of complex line-by-line parsing, extract key information directly
            
            // Extract certificate status
            if let certStatusRange = divContent.range(of: "Certificate Status:") {
                let remaining = divContent[certStatusRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let status = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    var cert = data["certificate"] as! [String: String]
                    cert["status"] = status
                    data["certificate"] = cert
                    log("Certificate Status: \(status)")
                }
            }
            
            // Extract certificate matching status
            if let matchStatusRange = divContent.range(of: "Certificate Matching Status:") {
                let remaining = divContent[matchStatusRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let status = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    data["certificate_matching_status"] = status
                    log("Certificate Matching Status: \(status)")
                }
            }
            
            // Extract effective and expiration dates
            if let effDateRange = divContent.range(of: "Effective Date:") {
                let remaining = divContent[effDateRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let date = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    var cert = data["certificate"] as! [String: String]
                    cert["effective"] = date
                    data["certificate"] = cert
                }
            }
            
            if let expDateRange = divContent.range(of: "Expiration Date:") {
                let remaining = divContent[expDateRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let date = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    var cert = data["certificate"] as! [String: String]
                    cert["expiration"] = date
                    data["certificate"] = cert
                }
            }
            
            // Extract certificate name
            if let nameRange = divContent.range(of: "CertName:") {
                let remaining = divContent[nameRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let name = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    var cert = data["certificate"] as! [String: String]
                    cert["name"] = name
                    data["certificate"] = cert
                }
            }
            
            // Extract MP name
            if let mpNameRange = divContent.range(of: "MP Name:") {
                let remaining = divContent[mpNameRange.upperBound...]
                if let endOfLine = remaining.firstIndex(of: "\n") {
                    let name = String(remaining[..<endOfLine]).trimmingCharacters(in: .whitespaces)
                    var mp = data["mobileprovision"] as! [String: String]
                    mp["name"] = name
                    data["mobileprovision"] = mp
                }
            }
            
            // Check for key phrases to determine overall status
            let overallStatus: String
            if divContent.contains("🟢Good") || divContent.contains("🟢Match") {
                overallStatus = "Valid"
            } else if divContent.contains("🔴") {
                overallStatus = "Invalid"
            } else {
                overallStatus = "Unknown"
            }
            
            data["overall_status"] = overallStatus
            log("Overall Status: \(overallStatus)")
            
            log("Final parsed data: \(data)")
            log("=== Finished parseHTML() Successfully ===")
            return data
        } else {
            log("WARNING: No alert div found in HTML")
        }
    } else {
        log("ERROR: Could not create div regex")
    }
    
    // Fallback: Try to extract key information directly from HTML
    log("Attempting fallback parsing...")
    
    // Check for key status indicators in the raw HTML
    if html.contains("🟢Good") {
        data["overall_status"] = "Valid"
        log("Fallback: Found 🟢Good indicator")
    } else if html.contains("🔴Mismatch") || html.contains("🔴No Permission") {
        data["overall_status"] = "Invalid"
        log("Fallback: Found 🔴 indicator")
    } else {
        data["overall_status"] = "Unknown"
        log("Fallback: No clear status indicators found")
    }
    
    log("=== parseHTML() Completed with Fallback ===")
    
    return ["error": "Could not fully parse certificate info", 
            "overall_status": data["overall_status"] as? String ?? "Unknown",
            "raw_html_preview": String(html.prefix(1000))]
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
