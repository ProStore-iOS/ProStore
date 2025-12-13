// CertificatesManager.swift
import Foundation
import Security
import CryptoKit
import Combine

public enum CertificateCheckResult {
    case incorrectPassword
    case noMatch
    case success
}

public enum CertificateError: Error {
    case p12ImportFailed(OSStatus)
    case identityExtractionFailed
    case certExtractionFailed
    case noCertsInProvision
    case publicKeyExportFailed(OSStatus)
    case plistExtractionFailed
    case unknown
}

/// CertificatesManager handles cert extraction/checking and exposes the currently selected identity.
/// Replace `SecIdentity` with your own wrapper type if you use a custom model.
public final class CertificatesManager: ObservableObject {
    public static let shared = CertificatesManager()
    private init() {}

    // REMOVED: @Published public var selectedCertificate: SecIdentity? = nil

    /// Returns the currently selected SecIdentity by loading from the selected folder in UserDefaults
    public var selectedIdentity: SecIdentity? {
        guard let folderName = UserDefaults.standard.string(forKey: "selectedCertificateFolder"),
              !folderName.isEmpty else {
            return nil
        }

        let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(folderName)
        let p12URL = certDir.appendingPathComponent("certificate.p12")
        let pwURL = certDir.appendingPathComponent("password.txt")

        guard let p12Data = try? Data(contentsOf: p12URL),
              let password = try? String(contentsOf: pwURL, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12Data as CFData, options, &items)

        guard status == errSecSuccess,
              let cfItems = items as? [[String: Any]],
              let identityAny = cfItems.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identityAny as CFTypeRef) == SecIdentityGetTypeID() else {
            return nil
        }

        return identityAny as! SecIdentity
    }

    // MARK: - Utility: SHA256 hex
    public static func sha256Hex(_ d: Data) -> String {
        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Export public key bytes for a SecCertificate
    private static func publicKeyData(from cert: SecCertificate) throws -> Data {
        guard let secKey = SecCertificateCopyKey(cert) else {
            throw CertificateError.certExtractionFailed
        }

        var cfErr: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(secKey, &cfErr) as Data? else {
            if let cfError = cfErr?.takeRetainedValue() {
                let code = CFErrorGetCode(cfError)
                throw CertificateError.publicKeyExportFailed(OSStatus(code))
            } else {
                throw CertificateError.publicKeyExportFailed(-1)
            }
        }

        return keyData
    }

    // MARK: - Extract certificates array from mobileprovision (PKCS7) blob
    private static func certificatesFromMobileProvision(_ data: Data) throws -> [SecCertificate] {
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)

        guard let startRange = data.range(of: startTag),
              let endRange = data.range(of: endTag) else {
            throw CertificateError.plistExtractionFailed
        }

        let plistData = data[startRange.lowerBound..<endRange.upperBound]
        let parsed = try PropertyListSerialization.propertyList(from: Data(plistData), options: [], format: nil)

        guard let dict = parsed as? [String: Any] else {
            throw CertificateError.plistExtractionFailed
        }

        var resultCerts: [SecCertificate] = []
        if let devArray = dict["DeveloperCertificates"] as? [Any] {
            for item in devArray {
                if let certData = item as? Data {
                    if let secCert = SecCertificateCreateWithData(nil, certData as CFData) {
                        resultCerts.append(secCert)
                    }
                } else if let base64String = item as? String,
                          let certData = Data(base64Encoded: base64String) {
                    if let secCert = SecCertificateCreateWithData(nil, certData as CFData) {
                        resultCerts.append(secCert)
                    }
                }
            }
        }

        if resultCerts.isEmpty {
            throw CertificateError.noCertsInProvision
        }

        return resultCerts
    }

    // MARK: - Readable display name from mobileprovision
    public func getCertificateName(mobileProvisionData: Data) -> String? {
        // Extract the <plist>...</plist> block
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)
        guard let startRange = mobileProvisionData.range(of: startTag),
              let endRange = mobileProvisionData.range(of: endTag) else {
            return nil
        }

        let plistDataSlice = mobileProvisionData[startRange.lowerBound..<endRange.upperBound]
        let plistData = Data(plistDataSlice)

        guard let parsed = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = parsed as? [String: Any] else {
            return nil
        }

        if let teamName = dict["TeamName"] as? String, !teamName.isEmpty {
            return teamName
        }
        if let name = dict["Name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Top-level check: verify p12 matches one of the embedded certs in mobileprovision
    /// Returns .success(.success) if match, .success(.noMatch) if no match, or .failure(Error)
    public static func check(p12Data: Data, password: String, mobileProvisionData: Data) -> Result<CertificateCheckResult, Error> {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var itemsCF: CFArray?

        let importStatus = SecPKCS12Import(p12Data as CFData, options, &itemsCF)

        if importStatus == errSecAuthFailed {
            return .success(.incorrectPassword)
        }

        guard importStatus == errSecSuccess, let items = itemsCF as? [[String: Any]], items.count > 0 else {
            return .failure(CertificateError.p12ImportFailed(importStatus))
        }

        guard let first = items.first else {
            return .failure(CertificateError.identityExtractionFailed)
        }

        // kSecImportItemIdentity should be present
        guard let identityAny = first[kSecImportItemIdentity as String] else {
            return .failure(CertificateError.identityExtractionFailed)
        }

// Verify CFTypeID is SecIdentity, then force-cast
guard CFGetTypeID(identityAny as CFTypeRef) == SecIdentityGetTypeID() else {
    return .failure(CertificateError.identityExtractionFailed)
}
let identity = identityAny as! SecIdentity

        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certRef)

        guard certStatus == errSecSuccess, let p12Cert = certRef else {
            return .failure(CertificateError.certExtractionFailed)
        }

        do {
            let p12PubKeyData = try publicKeyData(from: p12Cert)
            let p12Hash = sha256Hex(p12PubKeyData)

            let embeddedCerts = try certificatesFromMobileProvision(mobileProvisionData)

            for cert in embeddedCerts {
                do {
                    let embPubKeyData = try publicKeyData(from: cert)
                    let embHash = sha256Hex(embPubKeyData)

                    if embHash == p12Hash {
                        return .success(.success)
                    }
                } catch {
                    // continue checking other embedded certs
                    continue
                }
            }

            return .success(.noMatch)
        } catch {
            return .failure(error)
        }
    }
}

