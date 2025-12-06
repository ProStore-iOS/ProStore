// CertTestView.swift
import SwiftUI

struct CertTestView: View {
    @State private var logs: String = "Logs will appear here...\n"
    @State private var generating = false
    
    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                Text(logs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .foregroundColor(.green)
                    .cornerRadius(12)
            }
            
            Button(action: generateCerts) {
                HStack {
                    if generating { ProgressView() }
                    Text(generating ? "Generating..." : "Generate Certificates")
                        .bold()
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
        .padding()
        .onAppear { loadLog() }
    }
    
    private func generateCerts() {
        generating = true
        Task {
            do {
                _ = try await GenerateCert.createAndSaveCerts()
                appendLog("✅ Certificates generated successfully.")
                loadLog()
            } catch {
                appendLog("❌ Error: \(error)")
            }
            generating = false
        }
    }
    
    private func loadLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logFile = docs.appendingPathComponent("log.txt")
        if let content = try? String(contentsOf: logFile) {
            logs = content
        }
    }
    
    private func appendLog(_ message: String) {
        logs += message + "\n"
    }
}

struct CertTestView_Previews: PreviewProvider {
    static var previews: some View {
        CertTestView()
    }
}