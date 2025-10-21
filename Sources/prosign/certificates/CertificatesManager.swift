// certificates.swift
import Foundation
import Security
import CryptoKit

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

public final class CertificatesManager {
    // SHA256 hex from Data
    static func sha256Hex(_ d: Data) -> String {
        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // Export public key bytes for a certificate (SecCertificate -> SecKey -> external representation)
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
    
    // Extract the <plist>...</plist> portion from a .mobileprovision (PKCS7) blob,
    // parse it to a dictionary and return SecCertificate objects from DeveloperCertificates.
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
    
    /// Get the certificate's display name (subject summary)
    public static func getCertificateName(mobileProvisionData: Data) -> String? {
        // Extract the <plist>...</plist> block from the mobileprovision (PKCS7) blob
        let startTag = Data("<plist".utf8)
        let endTag = Data("</plist>".utf8)
        guard let startRange = mobileProvisionData.range(of: startTag),
              let endRange = mobileProvisionData.range(of: endTag) else {
            return nil
        }

        let plistDataSlice = mobileProvisionData[startRange.lowerBound..<endRange.upperBound]
        let plistData = Data(plistDataSlice)

        // Parse plist into a dictionary
        guard let parsed = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = parsed as? [String: Any] else {
            return nil
        }

        // Prefer TeamName if present
        if let teamName = dict["TeamName"] as? String, !teamName.isEmpty {
            return teamName
        }

        // Fallback to Name (string)
        if let name = dict["Name"] as? String, !name.isEmpty {
            return name
        }

        return nil
    }
    
    /// Top-level check: returns result
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
        
        let identity = first[kSecImportItemIdentity as String] as! SecIdentity
        
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
                    continue
                }
            }
            
            return .success(.noMatch)
        } catch {
            return .failure(error)
        }
    }

}
