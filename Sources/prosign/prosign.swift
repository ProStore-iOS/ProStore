import SwiftUI

@main
struct ProSign: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                SignerView()
                    .navigationTitle("ProSign - Signer")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "hammer")
                Text("Signer")
            }

            NavigationStack {
                CertificateView()
                    .navigationTitle("ProSign - Certificates")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "key")
                Text("Certificates")
            }

            NavigationStack {
                AboutView()
                    .navigationTitle("ProSign - About")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "info.circle")
                Text("About")
            }
        }
    }
}
