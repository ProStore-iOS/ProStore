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

public final class CertificatesManager: ObservableObject {
    public static let shared = CertificatesManager()
    private init() {}

    /// Returns the currently selected SecIdentity by loading from the selected folder in UserDefaults
    public var selectedIdentity: SecIdentity? {
        guard let folderName = UserDefaults.standard.string(forKey: "selectedCertificateFolder"),
              !folderName.isEmpty else {
            return nil
        }

        let certDir = CertificateFileManager.shared.certificatesDirectory
            .appendingPathComponent(folderName)

        let p12URL = certDir.appendingPathComponent("certificate.p12")
        let pwURL  = certDir.appendingPathComponent("password.txt")

        guard let p12Data = try? Data(contentsOf: p12URL),
              let passwordRaw = try? String(contentsOf: pwURL, encoding: .utf8) else {
            return nil
        }

        let password = passwordRaw.trimmingCharacters(in: .whitespacesAndNewlines)

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

    // MARK: - SHA256 hex
    public static func sha256Hex(_ d: Data) -> String {
        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public key data
    private static func publicKeyData(from cert: SecCertificate) throws -> Data {
        guard let secKey = SecCertificateCopyKey(cert) else {
            throw CertificateError.certExtractionFailed
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            let code = error.map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) } ?? -1
            throw CertificateError.publicKeyExportFailed(code)
        }
        return data
    }

    // MARK: - Extract certs from mobileprovision
    private static func certificatesFromMobileProvision(_ data: Data) throws -> [SecCertificate] {
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)

        guard let startRange = data.range(of: startTag),
              let endRange = data.range(of: endTag) else {
            throw CertificateError.plistExtractionFailed
        }

        let plistData = data[startRange.lowerBound..<endRange.upperBound]
        let parsed = try PropertyListSerialization.propertyList(from: Data(plistData), options: [], format: nil)

        guard let dict = parsed as? [String: Any],
              let devArray = dict["DeveloperCertificates"] as? [Any] else {
            throw CertificateError.noCertsInProvision
        }

        var result: [SecCertificate] = []
        for item in devArray {
            if let certData = item as? Data,
               let cert = SecCertificateCreateWithData(nil, certData as CFData) {
                result.append(cert)
            } else if let base64 = item as? String,
                      let certData = Data(base64Encoded: base64),
                      let cert = SecCertificateCreateWithData(nil, certData as CFData) {
                result.append(cert)
            }
        }

        guard !result.isEmpty else { throw CertificateError.noCertsInProvision }
        return result
    }

    // MARK: - Display name from provision
    public func getCertificateName(mobileProvisionData: Data) -> String? {
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)
        guard let startRange = mobileProvisionData.range(of: startTag),
              let endRange = mobileProvisionData.range(of: endTag) else { return nil }

        let plistData = mobileProvisionData[startRange.lowerBound..<endRange.upperBound]
        guard let parsed = try? PropertyListSerialization.propertyList(from: Data(plistData), options: [], format: nil),
              let dict = parsed as? [String: Any] else { return nil }

        return (dict["TeamName"] as? String) ?? (dict["Name"] as? String)
    }

    // MARK: - Check p12 ↔ mobileprovision match
    public static func check(p12Data: Data, password: String, mobileProvisionData: Data) -> Result<CertificateCheckResult, Error> {
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?

        let status = SecPKCS12Import(p12Data as CFData, options, &items)

        if status == errSecAuthFailed { return .success(.incorrectPassword) }

        guard status == errSecSuccess,
              let itemsArray = items as? [[String: Any]],
              let identityAny = itemsArray.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identityAny as CFTypeRef) == SecIdentityGetTypeID(),
              let identity = identityAny as? SecIdentity else {
            return .failure(CertificateError.p12ImportFailed(status))
        }

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let p12Cert = certRef else {
            return .failure(CertificateError.certExtractionFailed)
        }

        do {
            let p12KeyData = try publicKeyData(from: p12Cert)
            let p12Hash = sha256Hex(p12KeyData)

            let embedded = try certificatesFromMobileProvision(mobileProvisionData)

            for cert in embedded {
                let keyData = try publicKeyData(from: cert)
                if sha256Hex(keyData) == p12Hash {
                    return .success(.success)
                }
            }
            return .success(.noMatch)
        } catch {
            return .failure(error)
        }
    }
}