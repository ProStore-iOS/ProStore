// installApp.swift
// Full implementation: parse IPA, generate manifest plist, host files on localhost (HTTP or TLS if PKCS12 present), open itms-services URL.
// Requires: ZIPFoundation (or replace unzip logic), Network, Security, UIKit (for UIApplication.open on iOS)

import Foundation
import Network
import Security
#if canImport(UIKit)
import UIKit
#endif
import ZIPFoundation // Make sure this package is added to your project

enum InstallAppError: Error {
    case unzipFailed(String)
    case payloadNotFound
    case infoPlistMissing
    case bundleParsingFailed
    case iconNotFound
    case fileWriteFailed(String)
    case serverStartFailed(String)
    case p12ImportFailed(String)
    case openURLFailed
}

// MARK: - Logging Utility

final class InstallLogger {
    static let shared = InstallLogger()
    private var logFileURL: URL?
    private let logQueue = DispatchQueue(label: "InstallLogger.queue")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    private init() {
        setupLogFile()
    }
    
    private func setupLogFile() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let fm = FileManager.default
            let logsDir = documents.appendingPathComponent("Logs", isDirectory: true)
            
            if !fm.fileExists(atPath: logsDir.path) {
                try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            }
            
            logFileURL = logsDir.appendingPathComponent("installLog.txt")
            
            // Create or append to log file
            let timestamp = dateFormatter.string(from: Date())
            let header = "\n\n=== Installation Log Started at \(timestamp) ===\n"
            if let logFileURL = logFileURL {
                if fm.fileExists(atPath: logFileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                        fileHandle.seekToEndOfFile()
                        if let headerData = header.data(using: .utf8) {
                            fileHandle.write(headerData)
                        }
                        fileHandle.closeFile()
                    }
                } else {
                    try header.write(to: logFileURL, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            print("Failed to setup log file: \(error)")
        }
    }
    
    func log(_ message: String, level: String = "INFO") {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"
        
        // Print to console
        print(logMessage, terminator: "")
        
        // Write to file
        logQueue.async {
            guard let logFileURL = self.logFileURL else { return }
            
            do {
                let fm = FileManager.default
                if !fm.fileExists(atPath: logFileURL.path) {
                    try logMessage.write(to: logFileURL, atomically: true, encoding: .utf8)
                } else {
                    if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                        fileHandle.seekToEndOfFile()
                        if let data = logMessage.data(using: .utf8) {
                            fileHandle.write(data)
                        }
                        fileHandle.closeFile()
                    } else {
                        try logMessage.write(to: logFileURL, atomically: true, encoding: .utf8)
                    }
                }
            } catch {
                print("Failed to write to log file: \(error)")
            }
        }
    }
    
    func logError(_ message: String) {
        log(message, level: "ERROR")
    }
    
    func logWarning(_ message: String) {
        log(message, level: "WARN")
    }
    
    func logDebug(_ message: String) {
        log(message, level: "DEBUG")
    }
    
    func logSuccess(_ message: String) {
        log(message, level: "SUCCESS")
    }
}

// MARK: - HTTP Server

final class LocalStaticHTTPServer {
    static let shared = LocalStaticHTTPServer()
    private var listener: NWListener?
    private var isTLS: Bool = false
    private var rootDirectory: URL?
    private let queue = DispatchQueue(label: "LocalStaticHTTPServer.queue")
    private var serverStarted = false
    private var activeConnections: Set<ConnectionWrapper> = []
    private let connectionsLock = NSLock()

    private struct ConnectionWrapper: Hashable {
    let connection: NWConnection
    
    static func == (lhs: ConnectionWrapper, rhs: ConnectionWrapper) -> Bool {
        return ObjectIdentifier(lhs.connection) == ObjectIdentifier(rhs.connection)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(connection))
    }
}

    // Start HTTP (or HTTPS if tlsIdentity is provided) on given port. Serves static files from rootDir.
    func start(host: NWEndpoint.Host = .ipv4(IPv4Address("127.0.0.1")!),
               port: UInt16 = 7404,
               rootDir: URL,
               tlsIdentity: sec_identity_t? = nil) throws -> UInt16
    {
        InstallLogger.shared.log("Starting HTTP server with port: \(port), tlsIdentity: \(tlsIdentity != nil ? "present" : "nil")")
        self.rootDirectory = rootDir
        self.serverStarted = false
        
        // Clear any existing connections
        connectionsLock.lock()
        activeConnections.removeAll()
        connectionsLock.unlock()

        // Create TCP params and attach TLS options if identity provided
        let tcpOptions = NWProtocolTCP.Options()
        let tlsOptions: NWProtocolTLS.Options? = {
            guard let identity = tlsIdentity else { 
                InstallLogger.shared.log("No TLS identity provided, using HTTP")
                return nil 
            }
            InstallLogger.shared.log("Configuring TLS options with provided identity")
            let options = NWProtocolTLS.Options()
            // configure TLS min/max
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
            // set local identity (the sec_identity_t)
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
            return options
        }()

        let params: NWParameters
        if let tls = tlsOptions {
            params = NWParameters(tls: tls, tcp: tcpOptions)
            isTLS = true
            InstallLogger.shared.log("Server configured with TLS (HTTPS)")
        } else {
            params = NWParameters(tls: nil, tcp: tcpOptions)
            isTLS = false
            InstallLogger.shared.log("Server configured without TLS (HTTP)")
        }

        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 0)
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
            InstallLogger.shared.log("NWListener created successfully")
        } catch {
            InstallLogger.shared.logError("NWListener init failed: \(error.localizedDescription)")
            throw InstallAppError.serverStartFailed("NWListener init failed: \(error.localizedDescription)")
        }

        // Create a semaphore to wait for server to start
        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            InstallLogger.shared.logDebug("New connection received")
            self.handleConnection(connection)
        }

        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                InstallLogger.shared.log("Server listener is READY")
                self.serverStarted = true
                startSemaphore.signal()
            case .failed(let err):
                InstallLogger.shared.logError("Listener failed: \(String(describing: err))")
                startError = err
                startSemaphore.signal()
            case .cancelled:
                InstallLogger.shared.log("Listener cancelled")
                startSemaphore.signal()
            case .waiting(let reason):
                InstallLogger.shared.log("Listener waiting: \(reason)")
            case .setup:
                InstallLogger.shared.log("Listener in setup state")
            @unknown default:
                InstallLogger.shared.log("Unknown listener state: \(newState)")
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        InstallLogger.shared.log("Listener started on queue")

        // Wait for server to start (with timeout)
        InstallLogger.shared.log("Waiting for server to become ready...")
        let timeoutResult = startSemaphore.wait(timeout: .now() + 10.0)
        
        if timeoutResult == .timedOut {
            InstallLogger.shared.logError("Server start timeout after 10 seconds")
            throw InstallAppError.serverStartFailed("Server start timeout")
        }
        
        if let error = startError {
            InstallLogger.shared.logError("Server failed to start: \(error.localizedDescription)")
            throw InstallAppError.serverStartFailed("Server failed to start: \(error.localizedDescription)")
        }
        
        if !serverStarted {
            InstallLogger.shared.logError("Server not started (serverStarted flag is false)")
            throw InstallAppError.serverStartFailed("Server not started")
        }

        // if we started with port 0 (ephemeral), get the actual port
        let actualPort: UInt16
        if let localEndpoint = listener.port {
            actualPort = UInt16(localEndpoint.rawValue)
            InstallLogger.shared.log("Server bound to port: \(actualPort)")
        } else {
            actualPort = port
            InstallLogger.shared.log("Using requested port: \(actualPort)")
        }

        InstallLogger.shared.logSuccess("Server successfully started on \(isTLS ? "https" : "http")://127.0.0.1:\(actualPort)")
        return actualPort
    }

    func stop() {
        InstallLogger.shared.log("Stopping HTTP server")
        
        connectionsLock.lock()
        for wrapper in activeConnections {
            wrapper.connection.cancel()
        }

        activeConnections.removeAll()
        connectionsLock.unlock()
        
        listener?.cancel()
        listener = nil
        serverStarted = false
    }

    // Very minimal GET-only static file handler.
    private func handleConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        activeConnections.insert(ConnectionWrapper(connection: connection))
        connectionsLock.unlock()
        
        var received = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    received.append(data)
                    // If header end reached
                    if let range = received.range(of: Data("\r\n\r\n".utf8)) {
                        self.processHTTPRequest(connection: connection, headerData: received.subdata(in: 0..<range.upperBound))
                        return
                    }
                }
                if isComplete || error != nil {
                    // try to process anyway
                    self.processHTTPRequest(connection: connection, headerData: received)
                } else {
                    receiveMore()
                }
            }
        }

        connection.start(queue: queue)
        receiveMore()
    }

    private func processHTTPRequest(connection: NWConnection, headerData: Data) {
        guard let header = String(data: headerData, encoding: .utf8) else { 
            InstallLogger.shared.logDebug("Failed to decode HTTP header")
            self.removeConnection(connection)
            return 
        }
        
        // Log the request (first line only for brevity)
        let lines = header.components(separatedBy: "\r\n")
        if let requestLine = lines.first {
            InstallLogger.shared.logDebug("HTTP Request: \(requestLine)")
        }
        
        // parse the request line
        guard let requestLine = lines.first else { 
            self.removeConnection(connection)
            return
        }
        let comps = requestLine.components(separatedBy: " ")
        guard comps.count >= 2 else { 
            self.removeConnection(connection)
            return
        }
        let method = comps[0]
        var path = comps[1]
        // strip query
        if let qIdx = path.firstIndex(of: "?") {
            path = String(path[..<qIdx])
        }
        // decode percent encodings
        path = path.removingPercentEncoding ?? path

        guard method == "GET" || method == "HEAD" else {
            InstallLogger.shared.logDebug("Method not allowed: \(method)")
            sendSimpleResponse(connection: connection, status: 405, text: "Method Not Allowed")
            return
        }

        // map "/" -> "/index.html"
        if path == "/" { path = "/index.html" }

        // compute file URL
        guard let root = rootDirectory else {
            InstallLogger.shared.logError("Root directory not set")
            sendSimpleResponse(connection: connection, status: 500, text: "Server misconfigured")
            return
        }

        // prevent path traversal
        let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = root.appendingPathComponent(cleaned)

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            InstallLogger.shared.logDebug("File not found: \(path)")
            sendSimpleResponse(connection: connection, status: 404, text: "Not Found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL)
            InstallLogger.shared.logDebug("Serving file: \(path) (\(data.count) bytes, \(mime))")
            var headers = "HTTP/1.1 200 OK\r\n"
            headers += "Content-Length: \(data.count)\r\n"
            headers += "Content-Type: \(mime)\r\n"
            headers += "Connection: close\r\n"
            headers += "\r\n"
            let headerDataToSend = Data(headers.utf8)
            connection.send(content: headerDataToSend, completion: .contentProcessed({ _ in
                connection.send(content: data, completion: .contentProcessed({ _ in
                    InstallLogger.shared.logDebug("File sent successfully: \(path)")
                    // Don't cancel immediately, let the client close
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.removeConnection(connection)
                    }
                }))
            }))
        } catch {
            InstallLogger.shared.logError("Read error for file \(path): \(error.localizedDescription)")
            sendSimpleResponse(connection: connection, status: 500, text: "Read error: \(error.localizedDescription)")
        }
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connectionsLock.lock()
        let wrapper = ConnectionWrapper(connection: connection)
        if activeConnections.contains(wrapper) {
            connection.cancel()
            activeConnections.remove(wrapper)
        }
        connectionsLock.unlock()
    }

    private func sendSimpleResponse(connection: NWConnection, status: Int, text: String) {
        let body = text + "\n"
        // fixed: build Data from full string rather than trying to add UTF8View slices
        let combined = Data(( "HTTP/1.1 \(status) \(self.httpStatusText(status))\r\n" +
                              "Content-Length: \(body.utf8.count)\r\n" +
                              "Content-Type: text/plain\r\n" +
                              "Connection: close\r\n\r\n" +
                              body ).utf8)
        connection.send(content: combined, completion: .contentProcessed({ _ in
            InstallLogger.shared.logDebug("Sent response: \(status) \(self.httpStatusText(status))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.removeConnection(connection)
            }
        }))
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "plist": return "text/xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ipa": return "application/octet-stream"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - High-level installApp implementation

/// Install a signed IPA:
/// 1) unzip and parse Info.plist to get app metadata and icon
/// 2) write files into Documents/AppFolder/<uuid> (app.ipa, icon.png, manifest.plist)
/// 3) start local HTTP server on 127.0.0.1 (attempt TLS if a PKCS#12 exists)
/// 4) open itms-services URL to trigger OTA install
public func installApp(from ipaURL: URL) throws {
    InstallLogger.shared.log("Starting installApp process")
    InstallLogger.shared.log("Source IPA: \(ipaURL.path)")
    
    let fm = FileManager.default
    InstallLogger.shared.log("FileManager initialized")
    
    // FIX: Remove 'try' from non-throwing function
    guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
        InstallLogger.shared.logError("Failed to get documents directory")
        throw InstallAppError.fileWriteFailed("Failed to get documents directory")
    }
    InstallLogger.shared.log("Documents directory: \(documents.path)")
    
    let appRoot = documents.appendingPathComponent("AppFolder", isDirectory: true)
    if !fm.fileExists(atPath: appRoot.path) {
        InstallLogger.shared.log("Creating AppFolder directory")
        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
    } else {
        InstallLogger.shared.log("AppFolder already exists")
    }

    // Use temp dir for extraction
    let uuid = UUID().uuidString
    InstallLogger.shared.log("Creating work directory with UUID: \(uuid)")
    let workDir = appRoot.appendingPathComponent(uuid, isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    InstallLogger.shared.log("Work directory: \(workDir.path)")

    // 1) Unzip IPA (IPA is a zip with /Payload/*.app)
    InstallLogger.shared.log("Unzipping IPA...")
    do {
        try fm.unzipItem(at: ipaURL, to: workDir)
        InstallLogger.shared.logSuccess("IPA unzipped successfully")
    } catch {
        InstallLogger.shared.logError("Unzip failed: \(error.localizedDescription)")
        throw InstallAppError.unzipFailed("Unzip failed: \(error.localizedDescription)")
    }

    // 2) find Payload/*.app
    let payloadDir = workDir.appendingPathComponent("Payload", isDirectory: true)
    InstallLogger.shared.log("Looking for Payload directory at: \(payloadDir.path)")
    
    guard let payloadContents = try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
          let appBundleURL = payloadContents.first(where: { $0.pathExtension == "app" }) else {
        InstallLogger.shared.logError("Payload directory not found or no .app bundle")
        throw InstallAppError.payloadNotFound
    }
    InstallLogger.shared.log("Found app bundle: \(appBundleURL.lastPathComponent)")

    // 3) read Info.plist
    let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")
    InstallLogger.shared.log("Looking for Info.plist at: \(infoPlistURL.path)")
    
    guard fm.fileExists(atPath: infoPlistURL.path),
          let infoData = try? Data(contentsOf: infoPlistURL) else {
        InstallLogger.shared.logError("Info.plist not found or unreadable")
        throw InstallAppError.infoPlistMissing
    }
    InstallLogger.shared.log("Info.plist found (\(infoData.count) bytes)")
    
    let plistAny: Any
    do {
        plistAny = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
        InstallLogger.shared.log("Info.plist parsed successfully")
    } catch {
        InstallLogger.shared.logError("Failed to parse Info.plist: \(error)")
        throw InstallAppError.bundleParsingFailed
    }
    
    guard let info = plistAny as? [String: Any] else {
        InstallLogger.shared.logError("Info.plist is not a dictionary")
        throw InstallAppError.bundleParsingFailed
    }

    // Get required fields
    let bundleIdentifier = (info["CFBundleIdentifier"] as? String) ?? ""
    let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "1.0"
    let title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ipaURL.deletingPathExtension().lastPathComponent
    
    InstallLogger.shared.log("App Info:")
    InstallLogger.shared.log("  Bundle Identifier: \(bundleIdentifier)")
    InstallLogger.shared.log("  Version: \(version)")
    InstallLogger.shared.log("  Title: \(title)")

    // 4) find app icon
    func findIcon(in info: [String: Any], appDir: URL) -> URL? {
        InstallLogger.shared.log("Searching for app icon...")
        
        // Parse CFBundleIcons -> CFBundlePrimaryIcon -> CFBundleIconFiles
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primary["CFBundleIconFiles"] as? [String],
           !iconFiles.isEmpty {
            InstallLogger.shared.log("Found CFBundleIconFiles: \(iconFiles)")
            
            // choose the last (often highest res) and try variants
            for candidate in iconFiles.reversed() {
                let namesToTry = [
                    candidate,
                    candidate + "@3x",
                    candidate + "@2x",
                    candidate + ".png",
                    candidate + "@2x.png",
                    candidate + "@3x.png"
                ]
                for name in namesToTry {
                    // search recursively in app dir
                    if let found = (try? fm.subpathsOfDirectory(atPath: appDir.path))?.first(where: { ($0 as NSString).lastPathComponent == name }) {
                        // build file URL
                        let fileURL = URL(fileURLWithPath: appDir.path).appendingPathComponent(found)
                        InstallLogger.shared.log("Found icon via CFBundleIconFiles: \(found)")
                        return fileURL
                    }
                }
            }
        }

        // fallback: try iTunesArtwork / AppIcon60x60@2x.png heuristics
        InstallLogger.shared.log("Trying fallback icon search...")
        let candidates = try? fm.subpathsOfDirectory(atPath: appDir.path)
        let pngs = candidates?.filter { $0.lowercased().hasSuffix(".png") } ?? []
        InstallLogger.shared.log("Found \(pngs.count) PNG files in app bundle")
        
        // prefer files whose name contains "icon" or "appicon" or "itunesartwork"
        if let iconPath = pngs.first(where: { $0.lowercased().contains("icon") || $0.lowercased().contains("itunesartwork") || $0.lowercased().contains("appicon") }) {
            InstallLogger.shared.log("Found icon via name pattern: \(iconPath)")
            return URL(fileURLWithPath: appDir.path).appendingPathComponent(iconPath)
        }
        // fallback to any png (small chance)
        if let any = pngs.first {
            InstallLogger.shared.log("Using first PNG as fallback: \(any)")
            return URL(fileURLWithPath: appDir.path).appendingPathComponent(any)
        }
        
        InstallLogger.shared.logWarning("No icon found")
        return nil
    }

    let iconURL = findIcon(in: info, appDir: appBundleURL)

    // Write final files into workDir (copy ipa, write icon, write manifest)
    let finalIPAURL = workDir.appendingPathComponent("app.ipa")
    InstallLogger.shared.log("Copying IPA to work directory: \(finalIPAURL.path)")
    do {
        if fm.fileExists(atPath: finalIPAURL.path) {
            InstallLogger.shared.log("Removing existing app.ipa")
            try fm.removeItem(at: finalIPAURL)
        }
        try fm.copyItem(at: ipaURL, to: finalIPAURL)
        InstallLogger.shared.logSuccess("IPA copied successfully")
    } catch {
        InstallLogger.shared.logError("Copy IPA failed: \(error.localizedDescription)")
        throw InstallAppError.fileWriteFailed("Copy IPA failed: \(error.localizedDescription)")
    }

    // copy icon if found, else leave blank
    var finalIconURL: URL?
    if let iconURL = iconURL {
        let dest = workDir.appendingPathComponent("icon.png")
        InstallLogger.shared.log("Copying icon from \(iconURL.path) to \(dest.path)")
        do {
            // Some icons might be in PNG format with a weird header (Apple PNG). But usually copying works.
            try fm.copyItem(at: iconURL, to: dest)
            finalIconURL = dest
            InstallLogger.shared.logSuccess("Icon copied successfully")
        } catch {
            // ignore icon failure
            InstallLogger.shared.logWarning("Icon copy failed: \(error.localizedDescription)")
        }
    } else {
        InstallLogger.shared.log("No icon to copy")
    }

    // 5) generate manifest plist dynamically
    func makeManifest(bundleId: String, version: String, title: String, ipaPath: String, iconPath: String?) -> Data? {
        InstallLogger.shared.log("Generating manifest.plist...")
        // Build dictionary like the XML you provided
        var assetList: [[String: Any]] = []

        // software-package entry
        let softwarePackage: [String: Any] = [
            "kind": "software-package",
            "url": ipaPath
        ]
        assetList.append(softwarePackage)

        // display-image (icon)
        if let iconPath = iconPath {
            InstallLogger.shared.log("Adding icon to manifest: \(iconPath)")
            let displayImage: [String: Any] = [
                "kind": "display-image",
                "needs-shine": false,
                "url": iconPath
            ]
            let fullSizeImage: [String: Any] = [
                "kind": "full-size-image",
                "needs-shine": false,
                "url": iconPath
            ]
            assetList.append(displayImage)
            assetList.append(fullSizeImage)
        }

        let metadata: [String: Any] = [
            "bundle-identifier": bundleId,
            "bundle-version": version,
            "kind": "software",
            "platform-identifier": "com.apple.platform.iphoneos",
            "title": title
        ]

        let item: [String: Any] = [
            "assets": assetList,
            "metadata": metadata
        ]

        let plistRoot: [String: Any] = [
            "items": [item]
        ]

        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistRoot, format: .xml, options: 0)
            InstallLogger.shared.logSuccess("Manifest.plist generated (\(plistData.count) bytes)")
            return plistData
        } catch {
            InstallLogger.shared.logError("Manifest plist serialization failed: \(error)")
            return nil
        }
    }

    // 6) Start local server. If PKCS#12 exists at Documents/SSL/localhost.p12, try to use it for TLS.
    InstallLogger.shared.log("Checking for PKCS#12 certificate...")
    let sslDir = documents.appendingPathComponent("SSL", isDirectory: true)
    var tlsIdentity: sec_identity_t? = nil
    let p12URL = sslDir.appendingPathComponent("localhost.p12")
    
    // Function to convert OSStatus to readable string
    func securityErrorToString(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }
        return "Unknown error: \(status)"
    }
    
    if fm.fileExists(atPath: p12URL.path) {
        InstallLogger.shared.log("Found PKCS12 file at \(p12URL.path)")
        do {
            let pData = try Data(contentsOf: p12URL)
            InstallLogger.shared.log("PKCS12 file size: \(pData.count) bytes")
            
            // Try with empty password first
            let options: CFDictionary = [kSecImportExportPassphrase as String: ""] as CFDictionary
            var items: CFArray? = nil
            let status = SecPKCS12Import(pData as CFData, options, &items)
            InstallLogger.shared.log("SecPKCS12Import status: \(status) - \(securityErrorToString(status))")
            
            if status == errSecSuccess,
               let arr = items as? [[String: Any]],
               let first = arr.first {
                InstallLogger.shared.log("PKCS12 import successful, items count: \(arr.count)")
                
                // The import dictionary values are Any; safely cast to SecIdentity
                if let identityAny = first[kSecImportItemIdentity as String] {
                    let identityRef = identityAny as! SecIdentity
                    InstallLogger.shared.log("SecIdentity cast successful")
                    // Convert to sec_identity_t for sec_protocol_options_set_local_identity()
                    if let secId = sec_identity_create(identityRef) {
                        tlsIdentity = secId
                        InstallLogger.shared.logSuccess("TLS identity created successfully")
                    } else {
                        InstallLogger.shared.logWarning("sec_identity_create failed; falling back to HTTP")
                    }
                } else {
                    // No identity entry in the import result
                    InstallLogger.shared.logWarning("PKCS#12 import produced no SecIdentity. Will use HTTP only.")
                }
            } else {
                // Try with common passwords if empty password fails
                InstallLogger.shared.log("Trying common passwords for PKCS12 file...")
                let commonPasswords = ["password", "123456", "admin", "localhost", "ssl", "cert", "prostore"]
                var foundPassword = false
                
                for password in commonPasswords {
                    let optionsWithPassword: CFDictionary = [kSecImportExportPassphrase as String: password] as CFDictionary
                    var passwordItems: CFArray? = nil
                    let passwordStatus = SecPKCS12Import(pData as CFData, optionsWithPassword, &passwordItems)
                    
                    if passwordStatus == errSecSuccess,
                       let arr = passwordItems as? [[String: Any]],
                       let first = arr.first,
                       let identityAny = first[kSecImportItemIdentity as String] {
                        
                        let identityRef = identityAny as! SecIdentity
                        if let secId = sec_identity_create(identityRef) {
                            tlsIdentity = secId
                            InstallLogger.shared.logSuccess("TLS identity created successfully with password: '\(password)'")
                            foundPassword = true
                            break
                        }
                    }
                }
                
                if !foundPassword {
                    InstallLogger.shared.logWarning("PKCS12 import failed even with common passwords. Will use HTTP only.")
                }
            }
        } catch {
            InstallLogger.shared.logError("Failed to read PKCS#12 file: \(error)")
        }
    } else {
        InstallLogger.shared.log("No PKCS#12 found at \(p12URL.path); using HTTP only")
    }

    // Now we can write files and start server with chosen protocol (https if tlsIdentity is present)
    // We'll pick port 7404 by default.
    let chosenPort: UInt16 = 7404
    let startedPort: UInt16
    InstallLogger.shared.log("Attempting to start server on port \(chosenPort)...")
    do {
        startedPort = try LocalStaticHTTPServer.shared.start(port: chosenPort, rootDir: workDir, tlsIdentity: tlsIdentity)
        InstallLogger.shared.logSuccess("Server started on port \(startedPort)")
        
        // Give the server a moment to stabilize
        InstallLogger.shared.log("Waiting for server to stabilize...")
        Thread.sleep(forTimeInterval: 0.5)
    } catch {
        InstallLogger.shared.logError("Failed to start local server: \(error)")
        throw InstallAppError.serverStartFailed("Failed to start local server: \(error)")
    }

    // Determine scheme based on whether we have tlsIdentity
    let scheme = (tlsIdentity != nil ? "https" : "http")
    InstallLogger.shared.log("Using scheme: \(scheme)")
    
    // Build URLs that manifest will point to
    let ipaURLString = "\(scheme)://127.0.0.1:\(startedPort)/app.ipa"
    InstallLogger.shared.log("IPA URL: \(ipaURLString)")
    
    var iconURLString: String? = nil
    if finalIconURL != nil {
        iconURLString = "\(scheme)://127.0.0.1:\(startedPort)/icon.png"
        InstallLogger.shared.log("Icon URL: \(iconURLString ?? "nil")")
    }

    // build manifest now
    InstallLogger.shared.log("Creating manifest with URLs...")
    guard let manifestData = makeManifest(bundleId: bundleIdentifier, version: version, title: title, ipaPath: ipaURLString, iconPath: iconURLString) else {
        InstallLogger.shared.logError("Manifest generation failed")
        throw InstallAppError.fileWriteFailed("Manifest generation failed")
    }

    let manifestURL = workDir.appendingPathComponent("manifest.plist")
    InstallLogger.shared.log("Writing manifest to: \(manifestURL.path)")
    do {
        try manifestData.write(to: manifestURL, options: .atomic)
        InstallLogger.shared.logSuccess("Manifest written successfully")
    } catch {
        InstallLogger.shared.logError("Write manifest failed: \(error.localizedDescription)")
        throw InstallAppError.fileWriteFailed("Write manifest failed: \(error.localizedDescription)")
    }

    // 7) Test server connectivity before opening URL
    InstallLogger.shared.log("Testing server connectivity...")
    let testURL = URL(string: "\(scheme)://127.0.0.1:\(startedPort)/manifest.plist")!
    InstallLogger.shared.log("Testing URL: \(testURL.absoluteString)")
    
    let session = URLSession(configuration: .default)
    let testSemaphore = DispatchSemaphore(value: 0)
    var testSuccess = false
    
    let testTask = session.dataTask(with: testURL) { data, response, error in
        if let error = error {
            InstallLogger.shared.logError("Server test failed: \(error.localizedDescription)")
        } else if let httpResponse = response as? HTTPURLResponse {
            InstallLogger.shared.log("Server test response: HTTP \(httpResponse.statusCode)")
            if httpResponse.statusCode == 200 {
                testSuccess = true
                InstallLogger.shared.logSuccess("Server test PASSED")
            } else {
                InstallLogger.shared.logError("Server test FAILED: Status \(httpResponse.statusCode)")
            }
        }
        testSemaphore.signal()
    }
    testTask.resume()
    
    // Wait for test with timeout
    let testTimeoutResult = testSemaphore.wait(timeout: .now() + 5.0)
    if testTimeoutResult == .timedOut {
        InstallLogger.shared.logWarning("Server test timed out after 5 seconds")
    }
    
    if !testSuccess {
        InstallLogger.shared.logWarning("Server test failed, but proceeding anyway")
    }

    // 8) Open itms-services URL to trigger installation
    let manifestRemoteURLString = "\(scheme)://127.0.0.1:\(startedPort)/manifest.plist"
    InstallLogger.shared.log("Manifest remote URL: \(manifestRemoteURLString)")
    
    guard let escaped = manifestRemoteURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let itms = URL(string: "itms-services://?action=download-manifest&url=\(escaped)") else {
        InstallLogger.shared.logError("Failed to create itms-services URL")
        throw InstallAppError.openURLFailed
    }
    
    InstallLogger.shared.log("itms-services URL: \(itms.absoluteString)")
    InstallLogger.shared.log("Attempting to open URL...")

    DispatchQueue.main.async {
        #if canImport(UIKit)
        InstallLogger.shared.log("Opening URL with UIApplication...")
        UIApplication.shared.open(itms, options: [:]) { success in
            if success {
                InstallLogger.shared.logSuccess("itms-services URL opened successfully")
            } else {
                InstallLogger.shared.logError("Failed to open itms-services URL")
            }
        }
        #else
        // macOS fallback (open in default browser)
        #if os(macOS)
        NSWorkspace.shared.open(itms)
        #endif
        #endif
    }

    // keep server running — caller can stop LocalStaticHTTPServer.shared.stop() when desired
    InstallLogger.shared.logSuccess("Installation process completed")
    InstallLogger.shared.log("Serving \(workDir.path) on \(scheme)://127.0.0.1:\(startedPort)")
    InstallLogger.shared.log("Manifest available at: \(manifestURL.path)")
    
    // Write a summary file for debugging
    let summary = """
    === Installation Summary ===
    Timestamp: \(Date())
    App: \(title)
    Bundle ID: \(bundleIdentifier)
    Version: \(version)
    Server URL: \(scheme)://127.0.0.1:\(startedPort)
    Manifest: \(manifestRemoteURLString)
    Work Directory: \(workDir.path)
    """
    
    let summaryURL = workDir.appendingPathComponent("installation_summary.txt")
    try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)
    InstallLogger.shared.log("Summary written to: \(summaryURL.path)")
}

