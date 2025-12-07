import Foundation
import OpenSSL

enum CertGenError: Error {
    case keyGenerationFailed(String)
    case x509CreationFailed(String)
    case writeFailed(String)
    case sanCreationFailed(String)
}

public final class GenerateCert {
   
    public static func createAndSaveCerts(caCN: String = "ProStore",
                                          serverCN: String = "127.0.0.1",
                                          rsaBits: Int32 = 2048,
                                          daysValid: Int32 = 36500) async throws -> [URL] {
       
        // Proper initialization for OpenSSL 3.x
        OPENSSL_init_ssl(UInt64(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS), nil)
        OPENSSL_init_crypto(UInt64(OPENSSL_INIT_LOAD_CONFIG | OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS), nil)
       
        guard let caPkey = try generateRSAKey(bits: rsaBits) else { 
            throw CertGenError.keyGenerationFailed("CA key generation failed") 
        }
       
        guard let caX509 = try createSelfSignedCertificate(pkey: caPkey, commonName: caCN, days: daysValid, isCA: true) else {
            EVP_PKEY_free(caPkey)
            throw CertGenError.x509CreationFailed("CA certificate creation failed")
        }
       
        guard let serverPkey = try generateRSAKey(bits: rsaBits) else { 
            EVP_PKEY_free(caPkey)
            X509_free(caX509)
            throw CertGenError.keyGenerationFailed("Server key generation failed") 
        }
       
        guard let serverX509 = try createCertificateSignedByCA(serverPKey: serverPkey, caPkey: caPkey, caX509: caX509, commonName: serverCN, days: daysValid) else {
            EVP_PKEY_free(caPkey)
            X509_free(caX509)
            EVP_PKEY_free(serverPkey)
            throw CertGenError.x509CreationFailed("Server certificate creation failed")
        }
       
        let docs = try documentsDirectory()
        let certDir = docs.appendingPathComponent("SSL", isDirectory: true)
        if !FileManager.default.fileExists(atPath: certDir.path) {
            try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)
        }
        let rootCertURL = certDir.appendingPathComponent("rootCA.pem")
        let finalCertURL = certDir.appendingPathComponent("ProStore.pem")
        let rootKeyURL = certDir.appendingPathComponent("rootCA.key.pem")
        let serverKeyURL = certDir.appendingPathComponent("localhost.key.pem")
        let serverCertURL = certDir.appendingPathComponent("localhost.crt.pem")
        let localhostP12URL = certDir.appendingPathComponent("localhost.p12")
       
        try writePrivateKeyPEM(pkey: caPkey, to: rootKeyURL.path)
        try writeX509PEM(x509: caX509, to: rootCertURL.path)
        try writeX509PEM(x509: caX509, to: finalCertURL.path)
       
        try writePrivateKeyPEM(pkey: serverPkey, to: serverKeyURL.path)
        try writeX509PEM(x509: serverX509, to: serverCertURL.path)
       
        // Try with password 'ProStore' first, which is what installApp.swift expects
        try writePKCS12(pkey: serverPkey, cert: serverX509, caCert: caX509, to: localhostP12URL.path, password: "ProStore")
       
        EVP_PKEY_free(caPkey)
        X509_free(caX509)
        EVP_PKEY_free(serverPkey)
        X509_free(serverX509)
       
        return [rootCertURL, rootKeyURL, serverKeyURL, serverCertURL, localhostP12URL]
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
        // Use modern EVP API for key generation in OpenSSL 3.x
        guard let ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nil) else {
            throw CertGenError.keyGenerationFailed("EVP_PKEY_CTX_new_id failed")
        }
        defer { EVP_PKEY_CTX_free(ctx) }
       
        if EVP_PKEY_keygen_init(ctx) <= 0 {
            throw CertGenError.keyGenerationFailed("EVP_PKEY_keygen_init failed")
        }
       
        if EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) <= 0 {
            throw CertGenError.keyGenerationFailed("EVP_PKEY_CTX_set_rsa_keygen_bits failed")
        }
       
        var pkey: OpaquePointer? = nil
        if EVP_PKEY_keygen(ctx, &pkey) <= 0 {
            throw CertGenError.keyGenerationFailed("EVP_PKEY_keygen failed")
        }
       
        return pkey
    }
    
    private static func createSelfSignedCertificate(pkey: OpaquePointer?,
                                                    commonName: String,
                                                    days: Int32,
                                                    isCA: Bool) throws -> OpaquePointer? {
        guard let x509 = X509_new() else { 
            throw CertGenError.x509CreationFailed("X509_new failed") 
        }
       
        X509_set_version(x509, 2)
       
        guard let serial = ASN1_INTEGER_new() else {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("ASN1_INTEGER_new failed")
        }
        defer { ASN1_INTEGER_free(serial) }
       
        if ASN1_INTEGER_set_int64(serial, 1) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("ASN1_INTEGER_set_int64 failed")
        }
       
        if X509_set_serialNumber(x509, serial) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_set_serialNumber failed")
        }
       
        // Set notBefore and notAfter using ASN1_TIME_set
        let currentTime = Int(time(nil))
       
        guard let notBefore = ASN1_TIME_set(nil, time_t(currentTime)) else {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("ASN1_TIME_set for notBefore failed")
        }
        defer { ASN1_TIME_free(notBefore) }
        if X509_set1_notBefore(x509, notBefore) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_set1_notBefore failed")
        }
       
        guard let notAfter = ASN1_TIME_set(nil, time_t(currentTime + Int(days) * 86400)) else {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("ASN1_TIME_set for notAfter failed")
        }
        defer { ASN1_TIME_free(notAfter) }
        if X509_set1_notAfter(x509, notAfter) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_set1_notAfter failed")
        }
       
        if X509_set_pubkey(x509, pkey) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_set_pubkey failed")
        }
       
        guard let name = X509_get_subject_name(x509) else {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_get_subject_name nil")
        }
       
        _ = addNameEntry(name: name, field: "O", value: "ProStore")
        _ = addNameEntry(name: name, field: "CN", value: commonName)
       
        if X509_set_issuer_name(x509, name) != 1 {
            X509_free(x509)
            throw CertGenError.x509CreationFailed("X509_set_issuer_name failed")
        }
       
        if isCA {
            if let ext = X509V3_EXT_conf_nid(nil, nil, NID_basic_constraints, "CA:TRUE") {
                defer { X509_EXTENSION_free(ext) }
                if X509_add_ext(x509, ext, -1) != 1 {
                    X509_free(x509)
                    throw CertGenError.x509CreationFailed("X509_add_ext for basic_constraints failed")
                }
            }
            if let ext2 = X509V3_EXT_conf_nid(nil, nil, NID_key_usage, "keyCertSign,cRLSign") {
                defer { X509_EXTENSION_free(ext2) }
                if X509_add_ext(x509, ext2, -1) != 1 {
                    X509_free(x509)
                    throw CertGenError.x509CreationFailed("X509_add_ext for key_usage failed")
                }
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
        guard let cert = X509_new() else { 
            throw CertGenError.x509CreationFailed("X509_new failed") 
        }
       
        X509_set_version(cert, 2)
       
        guard let serial = ASN1_INTEGER_new() else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("ASN1_INTEGER_new failed")
        }
        defer { ASN1_INTEGER_free(serial) }
       
        if ASN1_INTEGER_set_int64(serial, Int64(time(nil) & 0xffffffff)) != 1 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("ASN1_INTEGER_set_int64 failed")
        }
       
        if X509_set_serialNumber(cert, serial) != 1 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_set_serialNumber failed")
        }
       
        // Set notBefore and notAfter using ASN1_TIME_set
        let currentTime = Int(time(nil))
       
        guard let notBefore = ASN1_TIME_set(nil, time_t(currentTime)) else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("ASN1_TIME_set for notBefore failed")
        }
        defer { ASN1_TIME_free(notBefore) }
        if X509_set1_notBefore(cert, notBefore) != 1 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_set1_notBefore failed")
        }
       
        guard let notAfter = ASN1_TIME_set(nil, time_t(currentTime + Int(days) * 86400)) else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("ASN1_TIME_set for notAfter failed")
        }
        defer { ASN1_TIME_free(notAfter) }
        if X509_set1_notAfter(cert, notAfter) != 1 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_set1_notAfter failed")
        }
       
        if X509_set_pubkey(cert, serverPKey) != 1 {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_set_pubkey failed")
        }
       
        guard let subj = X509_get_subject_name(cert) else {
            X509_free(cert)
            throw CertGenError.x509CreationFailed("X509_get_subject_name nil")
        }
       
        _ = addNameEntry(name: subj, field: "O", value: "ProStore")
        _ = addNameEntry(name: subj, field: "CN", value: commonName)
       
        if let ca = caX509 {
            if let caSubject = X509_get_subject_name(ca) {
                if X509_set_issuer_name(cert, caSubject) != 1 {
                    X509_free(cert)
                    throw CertGenError.x509CreationFailed("X509_set_issuer_name failed")
                }
            }
        }
       
        // Try to add SAN, but ignore failure (no logging)
        do {
            try addSubjectAltName_IP_simple(cert: cert, ipString: "127.0.0.1")
        } catch {
            // intentionally ignored
        }
       
        if let ext_bc = X509V3_EXT_conf_nid(nil, nil, NID_basic_constraints, "CA:FALSE") {
            defer { X509_EXTENSION_free(ext_bc) }
            if X509_add_ext(cert, ext_bc, -1) != 1 {
                X509_free(cert)
                throw CertGenError.x509CreationFailed("X509_add_ext for basic_constraints failed")
            }
        }
       
        if let ext_ku = X509V3_EXT_conf_nid(nil, nil, NID_key_usage, "digitalSignature,keyEncipherment") {
            defer { X509_EXTENSION_free(ext_ku) }
            if X509_add_ext(cert, ext_ku, -1) != 1 {
                X509_free(cert)
                throw CertGenError.x509CreationFailed("X509_add_ext for key_usage failed")
            }
        }
       
        // Also add extended key usage for server authentication
        if let ext_eku = X509V3_EXT_conf_nid(nil, nil, NID_ext_key_usage, "serverAuth") {
            defer { X509_EXTENSION_free(ext_eku) }
            if X509_add_ext(cert, ext_eku, -1) != 1 {
                X509_free(cert)
                throw CertGenError.x509CreationFailed("X509_add_ext for ext_key_usage failed")
            }
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
    
    @discardableResult 
    private static func addNameEntry(name: OpaquePointer?, field: String, value: String) -> Int32 {
        guard let name = name else { return 0 }
        return value.withCString { valuePtr in
            return X509_NAME_add_entry_by_txt(name, field, MBSTRING_ASC, valuePtr, -1, -1, 0)
        }
    }
    
    // Simpler version that doesn't use deprecated stack functions
    private static func addSubjectAltName_IP_simple(cert: OpaquePointer?, ipString: String) throws {
        guard let cert = cert else { 
            throw CertGenError.sanCreationFailed("cert nil") 
        }
       
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
        guard let pkey = pkey else { 
            throw CertGenError.writeFailed("pkey nil") 
        }
        guard let bio = BIO_new_file(path, "w") else { 
            throw CertGenError.writeFailed("BIO_new_file failed for \(path)") 
        }
        defer { BIO_free_all(bio) }
       
        if PEM_write_bio_PrivateKey(bio, pkey, nil, nil, 0, nil, nil) != 1 {
            throw CertGenError.writeFailed("PEM_write_bio_PrivateKey failed for \(path)")
        }
    }
    
    private static func writeX509PEM(x509: OpaquePointer?, to path: String) throws {
        guard let x509 = x509 else { 
            throw CertGenError.writeFailed("x509 nil") 
        }
        guard let bio = BIO_new_file(path, "w") else { 
            throw CertGenError.writeFailed("BIO_new_file failed for \(path)") 
        }
        defer { BIO_free_all(bio) }
       
        if PEM_write_bio_X509(bio, x509) != 1 {
            throw CertGenError.writeFailed("PEM_write_bio_X509 failed for \(path)")
        }
    }
    
    private static func writePKCS12(pkey: OpaquePointer?, cert: OpaquePointer?, caCert: OpaquePointer?, to path: String, password: String?) throws {
        guard let pkey = pkey, let cert = cert else { 
            throw CertGenError.writeFailed("pkey or cert nil") 
        }
        
        // Always use an empty string if password is nil
        let passString = password ?? ""
        let pass: UnsafePointer<CChar>? = passString.utf8CString.withUnsafeBufferPointer { $0.baseAddress }
        
        let friendlyName = "localhost"
        let name: UnsafePointer<CChar>? = friendlyName.utf8CString.withUnsafeBufferPointer { $0.baseAddress }
        
        var caStack: OpaquePointer? = nil
        if let caCert = caCert {
            caStack = OPENSSL_sk_new_null()
            if let caStack = caStack {
                _ = OPENSSL_sk_push(caStack, UnsafeMutableRawPointer(caCert))
            }
        }
        
        defer {
            if let caStack = caStack {
                OPENSSL_sk_free(caStack)
            }
        }
        
        guard let p12 = PKCS12_create(pass, name, pkey, cert, caStack, 0, 0, 0, 0, 0) else {
            throw CertGenError.writeFailed("PKCS12_create failed")
        }
        defer { PKCS12_free(p12) }
        
        guard let bio = BIO_new_file(path, "wb") else { 
            throw CertGenError.writeFailed("BIO_new_file failed for \(path)") 
        }
        defer { BIO_free_all(bio) }
        
        if i2d_PKCS12_bio(bio, p12) != 1 {
            throw CertGenError.writeFailed("i2d_PKCS12_bio failed for \(path)")
        }
    }
}
