import SwiftUI
import UIKit

struct SetupView: View {
    var onComplete: () -> Void
    
    @State private var currentPage = 0
    @State private var isGeneratingCert = false
    @State private var certGenerated = false
    
    private let pages: [SetupPage] = [
        SetupPage(title: "Welcome to ProStore!",
                  subtitle: "Before you begin, follow these steps to make sure ProStore works perfectly.",
                  imageName: "star.fill"),
        
        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "When the popup appears, click the 'Close' button.",
                  imageName: "lock.shield"),
        
        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "ProStore will now automatically generate the SSL certificate and open it for installation.",
                  imageName: "sparkles"),
        
        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "Go to Settings, tap 'Profile Downloaded', then 'Install'. Enter your passcode, and confirm by tapping 'Install' on the popup.",
                  imageName: "checkmark.shield"),
        
        SetupPage(title: "Install the SSL Certificate",
                  subtitle: "Tap the tick, navigate to 'General → About → Certificate Trust Settings', and enable 'ProStore' under 'Enable Full Trust for Root Certificates'.",
                  imageName: "hand.thumbsup"),
        
        SetupPage(title: "You're finished!",
                  subtitle: "Thanks for completing the setup! You're now ready to use ProStore.",
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
    }
    
    private func generateCertificate() {
        isGeneratingCert = true
        Task {
            do {
                let urls = try await GenerateCert.createAndSaveCerts()
                
                // Find the ProStore.pem file
                if let proStoreCertURL = urls.first(where: { $0.lastPathComponent == "ProStore.pem" }) {
                    openCertificateFile(url: proStoreCertURL)
                }
                
                certGenerated = true
                isGeneratingCert = false
                Logger.shared.log("Certificate generated successfully.")
            } catch {
                isGeneratingCert = false
                Logger.shared.logError(error)
            }
        }
    }
    
    private func openCertificateFile(url: URL) {
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                // Fallback to UIDocumentInteractionController
                let docController = UIDocumentInteractionController(url: url)
                docController.presentOptionsMenu(from: CGRect.zero, in: UIApplication.shared.windows.first!.rootViewController!.view, animated: true)
            }
        }
    }
}

struct SetupPage {
    let title: String
    let subtitle: String
    let imageName: String
}