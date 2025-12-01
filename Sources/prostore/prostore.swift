import SwiftUI

@main
struct ProStore: App {
    var body: some Scene {
        WindowGroup {
            MainSidebarView()
        }
    }
}

struct MainSidebarView: View {
    @State private var selected: SidebarItem? = .apps

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                NavigationLink(value: SidebarItem.apps) {
                    Label("Apps", systemImage: "square.grid.2x2.fill")
                }
                NavigationLink(value: SidebarItem.signer) {
                    Label("Signer", systemImage: "hammer")
                }
                NavigationLink(value: SidebarItem.certificates) {
                    Label("Certificates", systemImage: "key")
                }
                NavigationLink(value: SidebarItem.updater) {
                    Label("Updater", systemImage: "square.and.arrow.down")
                }
                NavigationLink(value: SidebarItem.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("ProStore")
        } detail: {
            switch selected {
            case .signer:
                NavigationStack {
                    SignerView()
                        .navigationTitle("Signer")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .certificates:
                NavigationStack {
                    CertificateView()
                        .navigationTitle("Certificates")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .apps:
                NavigationStack {
                    AppsView(repoURLs: [
                        URL(string: "https://repository.apptesters.org/")!,
                        URL(string: "https://wuxu1.github.io/wuxu-complete.json")!,
                        URL(string: "https://wuxu1.github.io/wuxu-complete-plus.json")!,
                        URL(string: "https://raw.githubusercontent.com/RealBlackAstronaut/CelestialRepo/main/CelestialRepo.json")!,
                        URL(string: "https://ipa.cypwn.xyz/cypwn.json")!,
                        URL(string: "https://quarksources.github.io/dist/quantumsource.min.json")!,
                        URL(string: "https://bit.ly/quantumsource-plus-min")!,
                        URL(string: "https://raw.githubusercontent.com/Neoncat-OG/TrollStore-IPAs/main/apps_esign.json")!,
                        URL(string: "https://quarksources.github.io/altstore-complete.json")!
                    ])
                        .navigationTitle("Apps")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .about:
                NavigationStack {
                    AboutView()
                        .navigationTitle("About")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .updater:
                NavigationStack {
                    UpdaterView()
                        .navigationTitle("Updater")
                        .navigationBarTitleDisplayMode(.large)
                }
            case nil:
                Text("Select a section!")
            }
        }
    }
}

enum SidebarItem: Hashable {
    case signer
    case updater
    case certificates
    case apps
    case about
}


