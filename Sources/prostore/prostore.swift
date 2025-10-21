import SwiftUI

@main
struct ProStore: App {
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
                    .navigationTitle("ProStore - Signer")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "hammer")
                Text("Signer")
            }

            NavigationStack {
                CertificateView()
                    .navigationTitle("ProStore - Certificates")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "key")
                Text("Certificates")
            }

            NavigationStack {
                AboutView()
                    .navigationTitle("ProStore - About")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Image(systemName: "info.circle")
                Text("About")
            }
        }
    }
}
