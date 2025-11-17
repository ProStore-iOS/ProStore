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
    @State private var selected: SidebarItem? = .signer

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
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
                        .navigationTitle("ProStore - Signer")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .certificates:
                NavigationStack {
                    CertificateView()
                        .navigationTitle("ProStore - Certificates")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .about:
                NavigationStack {
                    AboutView()
                        .navigationTitle("ProStore - About")
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
    case about
}


