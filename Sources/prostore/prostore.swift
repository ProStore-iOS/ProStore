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
    @StateObject private var sourcesViewModel = SourcesViewModel()
    @State private var selected: SidebarItem? = .store

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                NavigationLink(value: SidebarItem.store) {
                    Label("Store", systemImage: "cart.fill")
                }
                NavigationLink(value: SidebarItem.certificates) {
                    Label("Certificates", systemImage: "key")
                }
                NavigationLink(value: SidebarItem.updater) {
                    Label("Updater", systemImage: "square.and.arrow.down")
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label("Settings", systemImage: "gear")
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
            case .store:
                NavigationStack {
                    AppsView()
                        .environmentObject(sourcesViewModel)
                        .navigationTitle("Store")
                        .navigationBarTitleDisplayMode(.large)
                }
            case .settings:
                NavigationStack {
                    SettingsView()
                        .environmentObject(sourcesViewModel)
                        .navigationTitle("Settings")
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
    case store
    case settings

}