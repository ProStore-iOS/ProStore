import SwiftUI
import UIKit
import GCDWebServer

// MARK: - Cert server manager
final class CertServerManager: ObservableObject {
    private var webServer: GCDWebServer?
    private var didServeOnce = false

    /// Start a web server that serves certURL at path /ProStore.crt, open the URL in Safari
    func serveAndOpen(certURL: URL) -> Bool {
        stopServer()
        didServeOnce = false

        let server = GCDWebServer()
        self.webServer = server

        server.addHandler(
            forMethod: "GET",
            path: "/ProStore.crt",
            request: GCDWebServerRequest.self,
            processBlock: { [weak self] request in
                do {
                    let data = try Data(contentsOf: certURL)
                    let response = GCDWebServerDataResponse(data: data, contentType: "application/x-x509-ca-cert")
                    response.setValue("attachment; filename=\"ProStore.crt\"", forAdditionalHeader: "Content-Disposition")

                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if !self.didServeOnce {
                            self.didServeOnce = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                self.stopServer()
                            }
                        }
                    }

                    return response
                } catch {
                    return GCDWebServerResponse(statusCode: 500)
                }
            }
        )

        let started = server.start(withPort: 0, bonjourName: nil)
        guard started, let serverURL = server.serverURL else {
            print("[CertServerManager] Failed to start web server")
            self.webServer = nil
            return false
        }

        let openURL = serverURL.appendingPathComponent("ProStore.crt")
        DispatchQueue.main.async {
            UIApplication.shared.open(openURL, options: [:]) { success in
                if !success {
                    print("[CertServerManager] Failed to open URL: \(openURL)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.stopServer()
                    }
                } else {
                    print("[CertServerManager] Opened URL: \(openURL)")
                }
            }
        }

        return true
    }

    func stopServer() {
        if let server = webServer, server.isRunning {
            server.stop()
            print("[CertServerManager] Server stopped")
        }
        webServer = nil
        didServeOnce = false
    }

    deinit {
        stopServer()
    }
}

// MARK: - SetupView
struct SetupView: View {
    var onComplete: () -> Void

    @State private var currentPage = 0
    @State private var isGeneratingCert = false
    @State private var certGenerated = false
    @State private var showStartFailedAlert = false

    @StateObject private var serverManager = CertServerManager()

    private let pages: [SetupPage] = [
        SetupPage(title: "Welcome to ProStore!",
                  subtitle: "Before you begin, follow these steps to make sure ProStore works perfectly.",
                  imageName: "star.fill"),
        
        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "ProStore will now generate the SSL certificate and open it for installation.\nTap the 'Generate Certificate' button, then when you get redirected, tap the 'Allow' button.\nWhen the popup appears, click the 'Close' button.",
                  imageName: "lock.shield"),

        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "Go to Settings, tap 'Profile Downloaded', then 'Install'.\nEnter your passcode, and confirm by tapping 'Install' on the popup.",
                  imageName: "checkmark.shield"),

        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "Tap the tick, then navigate to\n'General → About → Certificate Trust Settings'.\nEnable 'ProStore' under 'Enable Full Trust for Root Certificates'.",
                  imageName: "hand.thumbsup"),

        SetupPage(title: "You're finished!",
                  subtitle: "Thanks for completing the setup!\nYou're now ready to use ProStore.",
                  imageName: "party.popper")
    ]

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    VStack(spacing: 20) {
                        Image(systemName: pages[index].imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .foregroundColor(.accentColor)

                        Text(pages[index].title)
                            .font(.largeTitle)
                            .bold()
                            .multilineTextAlignment(.center)

                        Text(pages[index].subtitle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if index == 2 && !certGenerated {
                            if isGeneratingCert {
                                ProgressView("Generating certificate...")
                                    .padding(.top, 20)
                            } else {
                                Button("Generate Certificate") {
                                    generateCertificate()
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 20)
                            }
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .animation(.easeInOut, value: currentPage)

            Spacer()

            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation {
                            currentPage -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(currentPage == pages.count - 1 ? "Finish" : "Next") {
                    withAnimation {
                        if currentPage == 2 && !certGenerated {
                            generateCertificate()
                        } else if currentPage < pages.count - 1 {
                            currentPage += 1
                        } else {
                            onComplete()
                        }
                    }
                }
                .disabled(currentPage == 2 && !certGenerated)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            Spacer(minLength: 20)
        }
        .padding()
        .alert("Failed to start local web server", isPresented: $showStartFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't start the local web server to serve the certificate. Try again or check logs.")
        }
        .onDisappear {
            serverManager.stopServer()
        }
    }

    // MARK: - Certificate generation
    private func generateCertificate() {
        isGeneratingCert = true
        certGenerated = false

        Task {
            do {
                let urls = try await GenerateCert.createAndSaveCerts()

                guard let proStoreCertURL = urls.first(where: {
                    let name = $0.lastPathComponent.lowercased()
                    return name == "prostore.pem" || name == "prostore.crt" || name == "prostore.pem.crt"
                }) ?? urls.first else {
                    throw NSError(domain: "GenerateCert", code: -1, userInfo: [NSLocalizedDescriptionKey: "ProStore certificate file not found"])
                }

                let started = serverManager.serveAndOpen(certURL: proStoreCertURL)

                if !started {
                    showStartFailedAlert = true
                } else {
                    certGenerated = true
                }

                isGeneratingCert = false
            } catch {
                isGeneratingCert = false
            }
        }
    }
}

// MARK: - SetupPage model
struct SetupPage {
    let title: String
    let subtitle: String
    let imageName: String
}

