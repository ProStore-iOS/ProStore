import SwiftUI

@main
struct ProStore: App {
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup: Bool = false
    var body: some Scene {
        WindowGroup {
            if hasCompletedSetup {
                MainSidebarView()
            } else {
                SetupView {
                    hasCompletedSetup = true
                }
            }
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
                        URL(string: "https://raw.githubusercontent.com/swaggyP36000/TrollStore-IPAs/main/apps_esign.json")!,
                        URL(string: "https://ipa.cypwn.xyz/cypwn.json")!,
                        URL(string: "https://quarksources.github.io/dist/quantumsource.min.json")!,
                        URL(string: "https://bit.ly/quantumsource-plus-min")!,
                        URL(string: "https://raw.githubusercontent.com/Neoncat-OG/TrollStore-IPAs/main/apps_esign.json")!
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
    case updater
    case certificates
    case apps
    case about

}
