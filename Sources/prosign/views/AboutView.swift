// AboutView.swift
import SwiftUI

struct Credit: Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var profileURL: URL
    var avatarURL: URL
}

struct AboutView: View {
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
            role: "Zsign-Package (fork)",
            profileURL: URL(string: "https://github.com/khcrysalis")!,
            avatarURL: URL(string: "https://github.com/khcrysalis.png")!
        ),
        Credit(
            name: "Loyahdev",
            role: "iOS Certificates Source",
            profileURL: URL(string: "https://github.com/loyahdev")!,
            avatarURL: URL(string: "https://github.com/loyahdev.png")!
        )
    ]

    private var appIconURL: URL? {
        URL(string: "https://raw.githubusercontent.com/ProStore-iOS/ProSign/main/Sources/prosign/Assets.xcassets/AppIcon.appiconset/Icon-1024.png")
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

                    Text("ProSign")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Version \(versionString)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowInsets(EdgeInsets())

                Section(header: Text("Credits")) {
                    ForEach(credits) { c in
                        CreditRow(credit: c)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
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

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }

}
