// SettingsView.swift
import SwiftUI

struct Credit: Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var profileURL: URL
    var avatarURL: URL
}

struct SettingsView: View {
    @EnvironmentObject var sourcesViewModel: SourcesViewModel
    @State private var showingSourcesManager = false
    @State private var showingSetup = false
    
    private let credits: [Credit] = [
        Credit(
            name: "SuperGamer474",
            role: "Developer",
            profileURL: URL(string: "https://github.com/SuperGamer474")!,
            avatarURL: URL(string: "https://github.com/SuperGamer474.png")!
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
            name: "AppleP12",
            role: "Certificate Status Check",
            profileURL: URL(string: "https://check-p12.applep12.com/")!,
            avatarURL: URL(string: "https://applep12.com/favicon/apple-touch-icon.png")!
        )
    ]

    private var appIconURL: URL? {
        URL(string: "https://raw.githubusercontent.com/ProStore-iOS/ProStore/main/Sources/prostore/Assets.xcassets/AppIcon.appiconset/Icon-1024.png")
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: 8) {
                    if let url = appIconURL {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 120, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

                Section {
                    Button("Show Setup") {
                        showingSetup = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section(header: Text("Sources")) {
                    NavigationLink {
                        SourcesManagerView()
                    } label: {
                        Label("Sources Manager", systemImage: "link")
                    }
                    
                    DisclosureGroup("Current Sources") {
                        ForEach(sourcesViewModel.sources.prefix(3)) { source in
                            HStack {
                                Text(source.urlString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                if let url = source.url,
                                   let validationState = sourcesViewModel.validationStates[url] {
                                    Image(systemName: validationState.icon)
                                        .font(.caption2)
                                        .foregroundColor(validationState.color)
                                }
                            }
                        }
                        
                        if sourcesViewModel.sources.count > 3 {
                            Text("+ \(sourcesViewModel.sources.count - 3) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Credits")) {
                    ForEach(credits) { c in
                        CreditRow(credit: c)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                sourcesViewModel.validateAllSources()
            }
        }
        .sheet(isPresented: $showingSetup) {
            SetupView(onComplete: { showingSetup = false })
        }
    }
}

struct CreditRow: View {
    let credit: Credit
    @Environment(\.openURL) var openURL

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
            .overlay(Circle().stroke(Color(UIColor.separator), lineWidth: 0.5))

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
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 8)
    }
}