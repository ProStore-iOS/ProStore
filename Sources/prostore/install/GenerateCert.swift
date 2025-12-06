// GenerateCert.swift
import Foundation
import OpenSSL

enum CertGenError: Error {
    case keyGenerationFailed(String)
    case x509CreationFailed(String)
    case writeFailed(String)
    case sanCreationFailed(String)
}

final class Logger {
    static let shared = Logger()
    private let logFile: URL
    private let queue = DispatchQueue(label: "LoggerQueue")
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFile = docs.appendingPathComponent("log.txt")
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
    }
    
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullMsg = "[\(timestamp)] \(message)\n"
        print(fullMsg, terminator: "")
        queue.async {
            if let data = fullMsg.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFile.path) {
                    if let handle = try? FileHandle(forWritingTo: self.logFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: self.logFile)
                }
            }
        }
    }
    
    func logError(_ error: Error) {
        log("ERROR: \(error)")
    }
}

public final class GenerateCert {
    
    public static func createAndSaveCerts(caCN: String = "My Local CA",
                                          serverCN: String = "127.0.0.1",
                                          rsaBits: Int32 = 2048,
                                          daysValid: Int32 = 36500) async throws -> [URL] {
        Logger.shared.log("Initializing OpenSSL...")
        
        // Remove deprecated calls
        // _ = OpenSSL_add_all_algorithms() // Deprecated in OpenSSL 3.x
        // ERR_load_crypto_strings() // Deprecated in OpenSSL 3.x
        
        // For OpenSSL 3.x, use explicit initialization
        OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, nil)
        OPENSSL_init_crypto(OPENSSL_INIT_LOAD_CONFIG | OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS, nil)
        
        Logger.shared.log("Generating CA key...")
        guard let caPkey = try generateRSAKey(bits: rsaBits) else { throw CertGenError.keyGenerationFailed("CA key generation failed") }
        Logger.shared.log("CA key generated.")
        
        Logger.shared.log("Creating self-signed CA certificate...")
        guard let caX509 = try createSelfSignedCertificate(pkey: caPkey, commonName: caCN, days: daysValid, isCA: true) else {
            throw CertGenError.x509CreationFailed("CA certificate creation failed")
        }
        Logger.shared.log("CA certificate created.")
        
        Logger.shared.log("Generating server key...")
        guard let serverPkey = try generateRSAKey(bits: rsaBits) else { throw CertGenError.keyGenerationFailed("Server key generation failed") }
        Logger.shared.log("Server key generated.")
        
        Logger.shared.log("Creating server certificate signed by CA...")
        guard let serverX509 = try createCertificateSignedByCA(serverPKey: serverPkey, caPkey: caPkey, caX509: caX509, commonName: serverCN, days: daysValid) else {
            throw CertGenError.x509CreationFailed("Server certificate creation failed")
        }
        Logger.shared.log("Server certificate created.")
        
        let docs = try documentsDirectory()
        let rootCertURL = docs.appendingPathComponent("rootCA.pem")
        let rootKeyURL = docs.appendingPathComponent("rootCA.key.pem")
        let serverKeyURL = docs.appendingPathComponent("localhost.key.pem")
        let serverCertURL = docs.appendingPathComponent("localhost.crt.pem")
        
        Logger.shared.log("Writing CA key to \(rootKeyURL.path)")
        try writePrivateKeyPEM(pkey: caPkey, to: rootKeyURL.path)
        Logger.shared.log("Writing CA cert to \(rootCertURL.path)")
        try writeX509PEM(x509: caX509, to: rootCertURL.path)
        
        Logger.shared.log("Writing server key to \(serverKeyURL.path)")
        try writePrivateKeyPEM(pkey: serverPkey, to: serverKeyURL.path)
        Logger.shared.log("Writing server cert to \(serverCertURL.path)")
        try writeX509PEM(x509: serverX509, to: serverCertURL.path)
        
        Logger.shared.log("Certificate generation completed successfully.")
        
        EVP_PKEY_free(caPkey)
        X509_free(caX509)
        EVP_PKEY_free(serverPkey)
        X509_free(serverX509)
        
        return [rootCertURL, rootKeyURL, serverKeyURL, serverCertURL]
    }
    
    // MARK: - Helpers
    
    private static func documentsDirectory() throws -> URL {
        let fm = FileManager.default
        guard let url = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CertGenError.writeFailed("Documents directory not found")
        }
        return url
    }
    
    private static func generateRSAKey(bits: Int32) throws -> OpaquePointer? {
        guard let rsa = RSA_new() else { throw CertGenError.keyGenerationFailed("RSA_new failed") }
        guard let bn = BN_new() else { RSA_free(rsa); throw CertGenError.keyGenerationFailed("BN_new failed") }
        
        defer { BN_free(bn) }
        
        if BN_set_word(bn, UInt(65537)) != 1 {
            RSA_free(rsa)
            throw CertGenError.keyGenerationFailed("BN_set_word failed")
        }
        
        if RSA_generate_key_ex(rsa, bits, bn, nil) != 1 {
            RSA_free(rsa)
            throw CertGenError.keyGenerationFailed("RSA_generate_key_ex failed")
        }
        
        guard let pkey = EVP_PKEY_new() else {
            RSA_free(rsa)
            throw CertGenError.keyGenerationFailed("EVP_PKEY_new failed")
        }
        
        // Use EVP_PKEY_assign_RSA for OpenSSL 1.x compatibility
        // For OpenSSL 3.x, this should still work with the right headers
        if EVP_PKEY_assign(pkey, EVP_PKEY_RSA, rsa) != 1 {
            EVP_PKEY_free(pkey)
            RSA_free(rsa)
            throw CertGenError.keyGenerationFailed("EVP_PKEY_assign failed")
        }
        
        return pkey
    }

    private static func createSelfSignedCertificate(pkey: OpaquePointer?,
                                                    commonName: String,
                                                    days: Int32,
                                                    isCA: Bool) throws -> OpaquePointer? {
        guard let x509 = X509_new() else { throw CertGenError.x509CreationFailed("X509_new failed") }
        
        defer {
            if let x509 = x509 {
                // Only free if error occurs
            }
        }
        
        X509_set_version(x509, 2)
        
        if let serial = ASN1_INTEGER_new() {
            ASN1_INTEGER_set(serial, 1)
            X509_set_serialNumber(x509, serial)
            ASN1_INTEGER_free(serial)
        }
        
        X509_gmtime_adj(X509_get_notBefore(x509), 0)
        X509_gmtime_adj(X509_get_notAfter(x509), Int64(days) * 24 * 3600)
        X509_set_pubkey(x509, pkey)
        
        guard let name = X509_get_subject_name(x509) else {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_get_subject_name nil")
        }
        
        _ = addNameEntry(name: name, field: "C", value: "AU")
        _ = addNameEntry(name: name, field: "ST", value: "NSW")
        _ = addNameEntry(name: name, field: "L", value: "Sydney")
        _ = addNameEntry(name: name, field: "O", value: "MyCompany")
        _ = addNameEntry(name: name, field: "OU", value: "Dev")
        _ = addNameEntry(name: name, field: "CN", value: commonName)
        
        X509_set_issuer_name(x509, name)
        
        if isCA {
            if let ext = X509V3_EXT_conf_nid(nil, nil, NID_basic_constraints, "CA:TRUE") {
                X509_add_ext(x509, ext, -1)
                X509_EXTENSION_free(ext)
            }
            if let ext2 = X509V3_EXT_conf_nid(nil, nil, NID_key_usage, "keyCertSign,cRLSign") {
                X509_add_ext(x509, ext2, -1)
                X509_EXTENSION_free(ext2)
            }
        }
        
        if X509_sign(x509, pkey, EVP_sha256()) == 0 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_sign failed")
        }
        
        return x509
    }

    private static func createCertificateSignedByCA(serverPKey: OpaquePointer?,
                                                    caPkey: OpaquePointer?,
                                                    caX509: OpaquePointer?,
                                                    commonName: String,
                                                    days: Int32) throws -> OpaquePointer? {
        guard let cert = X509_new() else { throw CertGenError.x509CreationFailed("X509_new failed") }
        
        defer {
            if let cert = cert {
                // Only free if error occurs
            }
        }
        
        X509_set_version(cert, 2)
        
        if let serial = ASN1_INTEGER_new() {
            ASN1_INTEGER_set(serial, Int(time(nil) & 0xffffffff))
            X509_set_serialNumber(cert, serial)
            ASN1_INTEGER_free(serial)
        }
        
        X509_gmtime_adj(X509_get_notBefore(cert), 0)
        X509_gmtime_adj(X509_get_notAfter(cert), Int64(days) * 24 * 3600)
        X509_set_pubkey(cert, serverPKey)
        
        guard let subj = X509_get_subject_name(cert) else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_get_subject_name nil")
        }
        
        _ = addNameEntry(name: subj, field: "C", value: "AU")
        _ = addNameEntry(name: subj, field: "ST", value: "NSW")
        _ = addNameEntry(name: subj, field: "L", value: "Sydney")
        _ = addNameEntry(name: subj, field: "O", value: "MyCompany")
        _ = addNameEntry(name: subj, field: "OU", value: "Dev")
        _ = addNameEntry(name: subj, field: "CN", value: commonName)
        
        if let ca = caX509 {
            if let caSubject = X509_get_subject_name(ca) {
                X509_set_issuer_name(cert, caSubject)
            }
        }
        
        // Use the simpler method for SAN
        do { try addSubjectAltName_IP_simple(cert: cert, ipString: "127.0.0.1") } catch {
            Logger.shared.log("Warning: SAN add failed: \(error)")
        }
        
        if let ext_bc = X509V3_EXT_conf_nid(nil, nil, NID_basic_constraints, "CA:FALSE") {
            X509_add_ext(cert, ext_bc, -1)
            X509_EXTENSION_free(ext_bc)
        }
        
        if let ext_ku = X509V3_EXT_conf_nid(nil, nil, NID_key_usage, "digitalSignature,keyEncipherment") {
            X509_add_ext(cert, ext_ku, -1)
            X509_EXTENSION_free(ext_ku)
        }
        
        guard let caKey = caPkey else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("CA private key missing")
        }
        
        if X509_sign(cert, caKey, EVP_sha256()) == 0 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_sign with CA key failed")
        }
        
        return cert
    }

    @discardableResult private static func addNameEntry(name: OpaquePointer?, field: String, value: String) -> Int32 {
        guard let name = name else { return 0 }
        return value.withCString { valuePtr in
            return X509_NAME_add_entry_by_txt(name, field, MBSTRING_ASC, valuePtr, -1, -1, 0)
        }
    }

    // Simpler version that doesn't use deprecated stack functions
    private static func addSubjectAltName_IP_simple(cert: OpaquePointer?, ipString: String) throws {
        guard let cert = cert else { throw CertGenError.sanCreationFailed("cert nil") }
        
        // Create SAN string in format "IP:127.0.0.1"
        let sanString = "IP:\(ipString)"
        
        guard let ext = X509V3_EXT_conf_nid(nil, nil, NID_subject_alt_name, sanString) else {
            throw CertGenError.sanCreationFailed("X509V3_EXT_conf_nid failed for SAN")
        }
        
        defer { X509_EXTENSION_free(ext) }
        
        if X509_add_ext(cert, ext, -1) != 1 {
            throw CertGenError.sanCreationFailed("X509_add_ext failed for SAN")
        }
    }

    private static func writePrivateKeyPEM(pkey: OpaquePointer?, to path: String) throws {
        guard let pkey = pkey else { throw CertGenError.writeFailed("pkey nil") }
        guard let bio = BIO_new_file(path, "w") else { throw CertGenError.writeFailed("BIO_new_file failed for \(path)") }
        defer { BIO_free_all(bio) }
        
        if PEM_write_bio_PrivateKey(bio, pkey, nil, nil, 0, nil, nil) != 1 {
            throw CertGenError.writeFailed("PEM_write_bio_PrivateKey failed for \(path)")
        }
    }

    private static func writeX509PEM(x509: OpaquePointer?, to path: String) throws {
        guard let x509 = x509 else { throw CertGenError.writeFailed("x509 nil") }
        guard let bio = BIO_new_file(path, "w") else { throw CertGenError.writeFailed("BIO_new_file failed for \(path)") }
        defer { BIO_free_all(bio) }
        
        if PEM_write_bio_X509(bio, x509) != 1 {
            throw CertGenError.writeFailed("PEM_write_bio_X509 failed for \(path)")
        }
    }
}