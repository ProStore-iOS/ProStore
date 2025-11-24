import Foundation

public final class CertRevokeChecker {
    public static func checkRevocation(folderName: String) async -> String {
        let certDir = CertificateFileManager.shared.certificatesDirectory.appendingPathComponent(folderName)
        let p12URL = certDir.appendingPathComponent("certificate.p12")
        let provURL = certDir.appendingPathComponent("profile.mobileprovision")
        let passwordURL = certDir.appendingPathComponent("password.txt")
        
        var password = ""
        if let pwData = try? Data(contentsOf: passwordURL), let pw = String(data: pwData, encoding: .utf8) {
            password = pw
        }
        
        guard let p12Data = try? Data(contentsOf: p12URL),
              let provData = try? Data(contentsOf: provURL) else {
            return "Unknown"
        }
        
        guard let url = URL(string: "https://tools.nezushub.vip/cert-ios-checker/api/") else {
            return "Unknown"
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add p12 file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"certificate.p12\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(p12Data)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add mobileprovision file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"secondary_file\"; filename=\"profile.mobileprovision\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(provData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add password
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"password\"\r\n\r\n".data(using: .utf8)!)
        body.append(password.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success,
               let dataDict = json["data"] as? [String: Any],
               let certificate = dataDict["certificate"] as? [String: Any],
               let comparison = certificate["comparison_data"] as? [String: Any],
               let match = comparison["certificates_match"] as? Bool, match,
               let certStatus = certificate["certificate_status"] as? [String: Any],
               let status = certStatus["status"] as? String {
                return status
            } else {
                return "Unknown"
            }
        } catch {
            return "Unknown"
        }
    }
}
