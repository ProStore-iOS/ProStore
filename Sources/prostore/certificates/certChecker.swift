// CertRevokeChecker.swift
import Foundation

// MARK: - API Response Models
struct NezushubResponse: Decodable {
    let success: Bool
    let data: NezushubData?
    let message: String?
}

struct NezushubData: Decodable {
    let certificate: CertificateInfo
    let certificate_status: CertificateStatus
    let comparison_data: ComparisonData
    let entitlements: [String: AnyCodable]? // optional, not needed for UI
}

struct CertificateInfo: Decodable {
    let certificate_info: CertDetails
}

struct CertDetails: Decodable {
    let validity_period: ValidityPeriod
}

struct ValidityPeriod: Decodable {
    let valid_to: String // ISO 8601 date string
}

struct CertificateStatus: Decodable {
    let status: String      // e.g. "Signed", "Revoked"
    let ocsp_status: String // e.g. "Good", "Revoked"
}

struct ComparisonData: Decodable {
    let certificates_match: Bool
}

// Helper to allow AnyCodable when we don't care about a field
struct AnyCodable: Decodable { }

// MARK: - Public result used by UI
enum RevocationCheckResult {
    case success(isSigned: Bool, expires: Date, match: Bool)
    case failure(Error)
    case networkError
}

// MARK: - Revocation Checker
final class CertRevokeChecker {
    static let shared = CertRevokeChecker()
    private init() {}
    
    private let apiURL = URL(string: "https://tools.nezushub.vip/cert-ios-checker/api/")!
    
    /// Perform the revocation + match check using the external API
    func check(p12URL: URL, provisionURL: URL, password: String) async -> RevocationCheckResult {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Helper to append a file part
        func appendFile(_ data: Data, filename: String, fieldName: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        // Helper to append a text field
        func appendText(_ value: String, fieldName: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        // Read files (security-scoped for new imports)
        let p12Scoped = p12URL.startAccessingSecurityScopedResource()
        let provScoped = provisionURL.startAccessingSecurityScopedResource()
        defer {
            if p12Scoped { p12URL.stopAccessingSecurityScopedResource() }
            if provScoped { provisionURL.stopAccessingSecurityScopedResource() }
        }
        
        do {
            let p12Data = try Data(contentsOf: p12URL)
            let provData = try Data(contentsOf: provisionURL)
            
            appendFile(p12Data, filename: "certificate.p12", fieldName: "file")
            appendFile(provData, filename: "profile.mobileprovision", fieldName: "secondary_file")
            appendText(password, fieldName: "password")
            
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .networkError
            }
            
            let decoded = try JSONDecoder().decode(NezushubResponse.self, from: data)
            
            guard decoded.success, let nezData = decoded.data else {
                return .failure(NSError(domain: "CertRevokeChecker", code: -1, userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Unknown API error"]))
            }
            
            // Parse expiry date
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let expiryDate = formatter.date(from: nezData.certificate.certificate_info.validity_period.valid_to) else {
                return .failure(NSError(domain: "CertRevokeChecker", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not parse expiry date"]))
            }
            
            // Determine if it's actually signed (not revoked)
            let isSigned = nezData.certificate_status.status.lowercased() == "signed" &&
                           nezData.certificate_status.ocsp_status.lowercased() == "good"
            
            let match = nezData.comparison_data.certificates_match
            
            return .success(isSigned: isSigned, expires: expiryDate, match: match)
            
        } catch {
            return .failure(error)
        }
    }
}
