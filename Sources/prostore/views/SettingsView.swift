// SettingsView.swift
import SwiftUI

// MARK: - Credit model
struct Credit: Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var profileURL: URL
    var avatarURL: URL
}

// MARK: - SettingsView
struct SettingsView: View {
    @EnvironmentObject var sourcesViewModel: SourcesViewModel
    @State private var showingSourcesManager = false
    @State private var showingSetup = false

    // MARK: Credits
    private let credits: [Credit] = [
        Credit(
            name: "NovaDev404",
            role: "Developer",
            profileURL: URL(string: "https://github.com/NovaDev404")!,
            avatarURL: URL(string: "https://github.com/NovaDev404.png")!
        ),
        Credit(
            name: "Zhlynn",
            role: "Original zsign",
            profileURL: URL(string: "https://github.com/zhlynn")!,
            avatarURL: URL(string: "https://github.com/zhlynn.png")!
        ),
        Credit(
            name: "Khcrysalis",
            role: "Zsign-Package (fork) & iDeviceKit",
            profileURL: URL(string: "https://github.com/khcrysalis")!,
            avatarURL: URL(string: "https://github.com/khcrysalis.png")!
        ),
        Credit(
            name: "S0n1c",
            role: "IPA Installer (Used in Updater)",
            profileURL: URL(string: "https://s0n1c.ca/")!,
            avatarURL: URL(string: "https://files.catbox.moe/qg7h5p.png")!
        ),
        Credit(
            name: "NovaDev Cert Checker API",
            role: "Certificate Status Check",
            profileURL: URL(string: "https://NovaDev.vip/")!,
            avatarURL: URL(string: "https://novadev.vip/logo.png")!
        )
    ]

    // MARK: App metadata
    private var appIconURL: URL? {
        URL(string: "https://raw.githubusercontent.com/ProStore-iOS/ProStore/main/Sources/prostore/Assets.xcassets/AppIcon.appiconset/Icon-1024.png")
    }

    private var versionString: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
    }

    // MARK: Body
    var body: some View {
        NavigationStack {
            List {

                // MARK: Header
                VStack(spacing: 8) {
                    if let url = appIconURL {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 120, height: 120)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 20,
                                            style: .continuous
                                        )
                                    )
                                    .shadow(radius: 6)
                            } else if phase.error != nil {
                                Image(systemName: "app.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 80, height: 80)
                                    .foregroundColor(.secondary)
                            } else {
                                ProgressView()
                                    .frame(width: 80, height: 80)
                            }
                        }
                    }

                    Text("ProStore")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Version \(versionString)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowInsets(EdgeInsets())

                // MARK: Setup
                Section(header: Text("Setup")) {
                    Button("Show Setup") {
                        showingSetup = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                // MARK: Sources
                Section(header: Text("Sources")) {
                    NavigationLink {
                        SourcesManagerView()
                            .environmentObject(sourcesViewModel)
                    } label: {
                        Text("Sources Manager")
                    }
                }

                // MARK: Credits
                Section(header: Text("Credits")) {
                    ForEach(credits) { credit in
                        CreditRow(credit: credit)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                sourcesViewModel.validateAllSources()
            }
        }
        .sheet(isPresented: $showingSetup) {
            SetupView {
                showingSetup = false
            }
        }
    }
}

// MARK: - CreditRow
struct CreditRow: View {
    let credit: Credit
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: credit.avatarURL) { phase in
                if let img = phase.image {
                    img
                        .resizable()
                        .scaledToFill()
                } else if phase.error != nil {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color(UIColor.separator), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(credit.name)
                    .font(.body)
                Text(credit.role)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                openURL(credit.profileURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.large)
                    .foregroundColor(.primary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }

}

