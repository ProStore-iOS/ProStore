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
                    AppsView()
                        .navigationTitle("Apps")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .about:
                NavigationStack {
                    AboutView()
                        .navigationTitle("About")
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
    case certificates
    case apps
    case about
}


