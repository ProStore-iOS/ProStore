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
            
            // Clean up the content but preserve line breaks
            // First replace <br/> with newlines
            divContent = divContent.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            divContent = divContent.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            divContent = divContent.replacingOccurrences(of: "&emsp;", with: "    ", options: .caseInsensitive)
            
            // Now remove HTML tags
            let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
            divContent = tagRegex?.stringByReplacingMatches(in: divContent, range: NSRange(0..<divContent.utf16.count), withTemplate: "") ?? divContent
            
            // Remove emojis and special characters but keep text
            divContent = divContent.replacingOccurrences(of: "🟢", with: "")
            divContent = divContent.replacingOccurrences(of: "🔴", with: "")
            
            // Split into lines and clean each line
            let rawLines = divContent.components(separatedBy: .newlines)
            var lines: [String] = []
            
            for line in rawLines {
                let cleanedLine = line.trimmingCharacters(in: .whitespaces)
                if !cleanedLine.isEmpty {
                    lines.append(cleanedLine)
                }
            }
            
            log("Found \(lines.count) lines after cleaning")
            log("Lines: \(lines)")
            
            // Create a dictionary to store all parsed data
            var parsedDict: [String: String] = [:]
            
            // Parse each line
            for line in lines {
                // Handle different colon types
                let separators = [": ", "："]
                for separator in separators {
                    if line.contains(separator) {
                        let parts = line.components(separatedBy: separator)
                        if parts.count >= 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespaces)
                            let value = parts[1...].joined(separator: separator).trimmingCharacters(in: .whitespaces)
                            parsedDict[key] = value
                            break
                        }
                    }
                }
            }
            
            log("Parsed dictionary: \(parsedDict)")
            
            // Extract certificate info
            var cert = data["certificate"] as! [String: String]
            if let certName = parsedDict["CertName"] {
                cert["name"] = certName
            }
            if let effDate = parsedDict["Effective Date"] {
                cert["effective"] = effDate
            }
            if let expDate = parsedDict["Expiration Date"] {
                cert["expiration"] = expDate
            }
            if let issuer = parsedDict["Issuer"] {
                cert["issuer"] = issuer
            }
            if let country = parsedDict["Country"] {
                cert["country"] = country
            }
            if let org = parsedDict["Organization"] {
                cert["organization"] = org
            }
            if let numHex = parsedDict["Certificate Number (Hex)"] {
                cert["number_hex"] = numHex
            }
            if let numDec = parsedDict["Certificate Number (Decimal)"] {
                cert["number_decimal"] = numDec
            }
            if let certStatus = parsedDict["Certificate Status"] {
                cert["status"] = certStatus
            }
            data["certificate"] = cert
            
            // Extract mobileprovision info
            var mp = data["mobileprovision"] as! [String: String]
            if let mpName = parsedDict["MP Name"] {
                mp["name"] = mpName
            }
            if let appId = parsedDict["App ID"] {
                mp["app_id"] = appId
            }
            if let identifier = parsedDict["Identifier"] {
                mp["identifier"] = identifier
            }
            if let platform = parsedDict["Platform"] {
                mp["platform"] = platform
            }
            // Look for mobileprovision dates (they might be duplicates from certificate section)
            for (key, value) in parsedDict {
                let lk = key.lowercased()
                if lk.contains("effective date") && !lk.contains("cert") {
                    mp["effective"] = value
                }
                if lk.contains("expiration date") && !lk.contains("cert") {
                    mp["expiration"] = value
                }
            }
            data["mobileprovision"] = mp
            
            // Extract binding certificate info
            // Look for "Certificate 1" and related info
            var bc1 = data["binding_certificate_1"] as! [String: String]
            for (key, value) in parsedDict {
                if key.contains("Certificate 1") || key.contains("Certificate Status") {
                    bc1["status"] = value
                } else if key.contains("Certificate Number (Hex)") && (bc1["number_hex"] == nil) {
                    bc1["number_hex"] = value
                } else if key.contains("Certificate Number (Decimal)") && (bc1["number_decimal"] == nil) {
                    bc1["number_decimal"] = value
                }
            }
            data["binding_certificate_1"] = bc1
            
            // Extract certificate matching status
            if let matchStatus = parsedDict["Certificate Matching Status"] {
                data["certificate_matching_status"] = matchStatus
            }
            
            // Extract permissions
            var perms = data["permissions"] as! [String: String]
            let permKeys = [
                "Apple Push Notification Service",
                "HealthKit", 
                "VPN",
                "Communication Notifications",
                "Time-sensitive Notifications"
            ]
            
            for key in permKeys {
                if let value = parsedDict[key] {
                    perms[key] = value
                }
            }
            data["permissions"] = perms
            
            // Determine overall status
            let overallStatus: String
            if let certStatus = cert["status"], certStatus.lowercased().contains("good") {
                overallStatus = "Valid"
            } else if let matchStatus = data["certificate_matching_status"] as? String,
                     matchStatus.lowercased().contains("match") {
                overallStatus = "Valid"
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
    var overallStatus = "Unknown"
    if html.contains("🟢Good") && html.contains("🟢Match") {
        overallStatus = "Valid"
        log("Fallback: Found 🟢Good and 🟢Match indicators")
    } else if html.contains("🔴") {
        overallStatus = "Invalid"
        log("Fallback: Found 🔴 indicator")
    }
    
    data["overall_status"] = overallStatus
    log("Fallback Overall Status: \(overallStatus)")
    
    log("=== parseHTML() Completed with Fallback ===")
    
    return ["error": "Could not fully parse certificate info", 
            "overall_status": overallStatus,
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
