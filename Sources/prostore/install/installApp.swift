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

final class LocalStaticHTTPServer {
    static let shared = LocalStaticHTTPServer()
    private var listener: NWListener?
    private var isTLS: Bool = false
    private var rootDirectory: URL?
    private let queue = DispatchQueue(label: "LocalStaticHTTPServer.queue")

    // Start HTTP (or HTTPS if tlsIdentity is provided) on given port. Serves static files from rootDir.
    func start(host: NWEndpoint.Host = .ipv4(IPv4Address("127.0.0.1")!),
               port: UInt16 = 7404,
               rootDir: URL,
               tlsIdentity: sec_identity_t? = nil) throws -> UInt16
    {
        self.rootDirectory = rootDir

        // Create TCP params and attach TLS options if identity provided
        let tcpOptions = NWProtocolTCP.Options()
        let tlsOptions: NWProtocolTLS.Options? = {
            guard let identity = tlsIdentity else { return nil }
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
        } else {
            params = NWParameters(tls: nil, tcp: tcpOptions)
            isTLS = false
        }

        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 0)
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw InstallAppError.serverStartFailed("NWListener init failed: \(error.localizedDescription)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.queue)
            self.handleConnection(connection)
        }

        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                // listener ready
                break
            case .failed(let err):
                print("Listener failed: \(String(describing: err))")
            default: break
            }
        }

        listener.start(queue: queue)
        self.listener = listener

        // if we started with port 0 (ephemeral), get the actual port
        let actualPort: UInt16
        if let localEndpoint = listener.port {
            actualPort = UInt16(localEndpoint.rawValue)
        } else {
            actualPort = port
        }

        return actualPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // Very minimal GET-only static file handler.
    private func handleConnection(_ connection: NWConnection) {
        var received = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    received.append(data)
                    // If header end reached
                    if let range = received.range(of: Data("\r\n\r\n".utf8)) {
                        // fixed: use half-open Range 0..<range.upperBound
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

        receiveMore()
    }

    private func processHTTPRequest(connection: NWConnection, headerData: Data) {
        defer { connection.cancel() }

        guard let header = String(data: headerData, encoding: .utf8) else { return }
        // parse the request line
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let comps = requestLine.components(separatedBy: " ")
        guard comps.count >= 2 else { return }
        let method = comps[0]
        var path = comps[1]
        // strip query
        if let qIdx = path.firstIndex(of: "?") {
            path = String(path[..<qIdx])
        }
        // decode percent encodings
        path = path.removingPercentEncoding ?? path

        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(connection: connection, status: 405, text: "Method Not Allowed")
            return
        }

        // map "/" -> "/index.html"
        if path == "/" { path = "/index.html" }

        // compute file URL
        guard let root = rootDirectory else {
            sendSimpleResponse(connection: connection, status: 500, text: "Server misconfigured")
            return
        }

        // prevent path traversal
        let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = root.appendingPathComponent(cleaned)

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            sendSimpleResponse(connection: connection, status: 404, text: "Not Found")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mime = mimeType(for: fileURL)
            var headers = "HTTP/1.1 200 OK\r\n"
            headers += "Content-Length: \(data.count)\r\n"
            headers += "Content-Type: \(mime)\r\n"
            headers += "Connection: close\r\n"
            headers += "\r\n"
            let headerDataToSend = Data(headers.utf8)
            connection.send(content: headerDataToSend, completion: .contentProcessed({ _ in
                connection.send(content: data, completion: .contentProcessed({ _ in
                    // done
                }))
            }))
        } catch {
            sendSimpleResponse(connection: connection, status: 500, text: "Read error: \(error.localizedDescription)")
        }
    }

    private func sendSimpleResponse(connection: NWConnection, status: Int, text: String) {
        let body = text + "\n"
        // fixed: build Data from full string rather than trying to add UTF8View slices
        let combined = Data(( "HTTP/1.1 \(status) \(httpStatusText(status))\r\n" +
                              "Content-Length: \(body.utf8.count)\r\n" +
                              "Content-Type: text/plain\r\n" +
                              "Connection: close\r\n\r\n" +
                              body ).utf8)
        connection.send(content: combined, completion: .contentProcessed({ _ in }))
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
    let fm = FileManager.default
    let documents = try fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    let appRoot = documents.appendingPathComponent("AppFolder", isDirectory: true)
    if !fm.fileExists(atPath: appRoot.path) {
        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
    }

    // Use temp dir for extraction
    let uuid = UUID().uuidString
    let workDir = appRoot.appendingPathComponent(uuid, isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

    // 1) Unzip IPA (IPA is a zip with /Payload/*.app)
    do {
        try fm.unzipItem(at: ipaURL, to: workDir)
    } catch {
        throw InstallAppError.unzipFailed("Unzip failed: \(error.localizedDescription)")
    }

    // 2) find Payload/*.app
    let payloadDir = workDir.appendingPathComponent("Payload", isDirectory: true)
    guard let payloadContents = try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
          let appBundleURL = payloadContents.first(where: { $0.pathExtension == "app" }) else {
        throw InstallAppError.payloadNotFound
    }

    // 3) read Info.plist
    let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")
    guard fm.fileExists(atPath: infoPlistURL.path),
          let infoData = try? Data(contentsOf: infoPlistURL) else {
        throw InstallAppError.infoPlistMissing
    }
    let plistAny = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
    guard let info = plistAny as? [String: Any] else {
        throw InstallAppError.bundleParsingFailed
    }

    // Get required fields
    let bundleIdentifier = (info["CFBundleIdentifier"] as? String) ?? ""
    let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "1.0"
    let title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ipaURL.deletingPathExtension().lastPathComponent

    // 4) find app icon
    func findIcon(in info: [String: Any], appDir: URL) -> URL? {
        // Parse CFBundleIcons -> CFBundlePrimaryIcon -> CFBundleIconFiles
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primary["CFBundleIconFiles"] as? [String],
           !iconFiles.isEmpty {
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
                        return fileURL
                    }
                }
            }
        }

        // fallback: try iTunesArtwork / AppIcon60x60@2x.png heuristics
        let candidates = try? fm.subpathsOfDirectory(atPath: appDir.path)
        let pngs = candidates?.filter { $0.lowercased().hasSuffix(".png") } ?? []
        // prefer files whose name contains "icon" or "appicon" or "itunesartwork"
        if let iconPath = pngs.first(where: { $0.lowercased().contains("icon") || $0.lowercased().contains("itunesartwork") || $0.lowercased().contains("appicon") }) {
            return URL(fileURLWithPath: appDir.path).appendingPathComponent(iconPath)
        }
        // fallback to any png (small chance)
        if let any = pngs.first {
            return URL(fileURLWithPath: appDir.path).appendingPathComponent(any)
        }
        return nil
    }

    let iconURL = findIcon(in: info, appDir: appBundleURL)

    // Write final files into workDir (copy ipa, write icon, write manifest)
    let finalIPAURL = workDir.appendingPathComponent("app.ipa")
    do {
        if fm.fileExists(atPath: finalIPAURL.path) {
            try fm.removeItem(at: finalIPAURL)
        }
        try fm.copyItem(at: ipaURL, to: finalIPAURL)
    } catch {
        throw InstallAppError.fileWriteFailed("Copy IPA failed: \(error.localizedDescription)")
    }

    // copy icon if found, else leave blank
    var finalIconURL: URL?
    if let iconURL = iconURL {
        let dest = workDir.appendingPathComponent("icon.png")
        do {
            // Some icons might be in PNG format with a weird header (Apple PNG). But usually copying works.
            try fm.copyItem(at: iconURL, to: dest)
            finalIconURL = dest
        } catch {
            // ignore icon failure
            print("Icon copy failed: \(error.localizedDescription)")
        }
    }

    // 5) generate manifest plist dynamically
    func makeManifest(bundleId: String, version: String, title: String, ipaPath: String, iconPath: String?) -> Data? {
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
            return plistData
        } catch {
            print("Manifest plist serialization failed: \(error)")
            return nil
        }
    }

// 6) Start local server. If PKCS#12 exists at Documents/SSL/localhost.p12, try to use it for TLS.
let sslDir = documents.appendingPathComponent("SSL", isDirectory: true)
var tlsIdentity: sec_identity_t? = nil
var tlsEnabled = false
let p12URL = sslDir.appendingPathComponent("localhost.p12")

if fm.fileExists(atPath: p12URL.path) {
    if let pData = try? Data(contentsOf: p12URL) {
        // PKCS#12 has no password; pass empty string
        let options: CFDictionary = [kSecImportExportPassphrase as String: ""] as CFDictionary
        var items: CFArray? = nil
        let status = SecPKCS12Import(pData as CFData, options, &items)

        if status == errSecSuccess,
           let arr = items as? [[String: Any]],
           let first = arr.first {
            
            // The import dictionary values are Any; safely cast to SecIdentity
            if let identityAny = first[kSecImportItemIdentity as String] {
                let identityRef = identityAny as! SecIdentity
                // Convert to sec_identity_t for sec_protocol_options_set_local_identity()
                if let secId = sec_identity_create(identityRef) {
                    tlsIdentity = secId
                    tlsEnabled = true
                    print("TLS identity loaded from PKCS#12 — TLS enabled.")
                    // NOTE: Do NOT free sec_identity_t here; leave it for the listener while running.
                } else {
                    print("sec_identity_create failed; falling back to HTTP")
                }
            } else {
                // No identity entry in the import result
                print("PKCS#12 import produced no SecIdentity. Will start HTTP only.")
            }

        } else {
            print("PKCS12 import failed (status \(status)). Will start HTTP only.")
        }
    } else {
        print("Failed to read PKCS#12 file at \(p12URL.path); starting HTTP only.")
    }
} else {
    print("No PKCS#12 found at \(p12URL.path); starting HTTP only.")
}

    // Now we can write files and start server with chosen protocol (https if tlsEnabled)
    // We'll pick port 7404 by default.
    let chosenPort: UInt16 = 7404
    let startedPort: UInt16
    do {
        startedPort = try LocalStaticHTTPServer.shared.start(port: chosenPort, rootDir: workDir, tlsIdentity: tlsIdentity)
    } catch {
        throw InstallAppError.serverStartFailed("Failed to start local server: \(error)")
    }

    let scheme = (tlsEnabled ? "https" : "http")
    // Build URLs that manifest will point to
    let ipaURLString = "\(scheme)://127.0.0.1:\(startedPort)/app.ipa"
    var iconURLString: String? = nil
    if finalIconURL != nil {
        iconURLString = "\(scheme)://127.0.0.1:\(startedPort)/icon.png"
    }

    // build manifest now
    guard let manifestData = makeManifest(bundleId: bundleIdentifier, version: version, title: title, ipaPath: ipaURLString, iconPath: iconURLString) else {
        throw InstallAppError.fileWriteFailed("Manifest generation failed")
    }

    let manifestURL = workDir.appendingPathComponent("manifest.plist")
    do {
        try manifestData.write(to: manifestURL, options: .atomic)
    } catch {
        throw InstallAppError.fileWriteFailed("Write manifest failed: \(error.localizedDescription)")
    }

    // 7) Open itms-services URL to trigger installation
    let manifestRemoteURLString = "\(scheme)://127.0.0.1:\(startedPort)/manifest.plist"
    guard let escaped = manifestRemoteURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let itms = URL(string: "itms-services://?action=download-manifest&url=\(escaped)") else {
        throw InstallAppError.openURLFailed
    }

    DispatchQueue.main.async {
        #if canImport(UIKit)
        UIApplication.shared.open(itms, options: [:]) { success in
            if !success {
                print("Failed to open itms-services URL")
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
    print("Serving \(workDir.path) on \(scheme)://127.0.0.1:\(startedPort) — manifest at \(manifestURL.path)")
}